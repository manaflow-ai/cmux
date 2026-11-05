import AppKit
import CmuxNextDesign
public import CmuxNextMobile
import CmuxNextWakeups
import Foundation

/// Local admission for the separately served Phone Access link. Always Ask: only a
/// person on this Mac may persist its TLS-proved endpoint in the shared phone list.
@MainActor
final class PhoneAdmission {
    enum PromptResult: Sendable, Equatable { case allow, deny, unavailable }
    @MainActor
    private final class PromptWaiter {
        private var continuation: CheckedContinuation<PromptResult, Never>?
        private var cancelled = false

        func wait(_ operation: @escaping () async -> PromptResult) async -> PromptResult {
            await withCheckedContinuation { continuation in
                guard !cancelled else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                self.continuation = continuation
                Task { @MainActor [self] in self.finish(await operation()) }
            }
        }

        func finish(_ result: PromptResult) {
            guard let continuation else {
                cancelled = true
                return
            }
            self.continuation = nil
            continuation.resume(returning: result)
        }
    }

    private struct Question {
        var id: UUID
        var accountGeneration: UInt64
        var admissionGeneration: UInt64
        var servingPeriod: UInt64
        var task: Task<Bool, Never>
        var cancel: () -> Void
    }

    static let dialogIdentifier = "cmux.dialog.phoneAccessAllow"
    private let phones: MobileHostPairedStore
    private var questions: [String: Question] = [:]
    private var denied: [String: ContinuousClock.Instant] = [:]
    private var generation: UInt64
    /// Invalidates one endpoint's pending answer without invalidating other phones.
    private var admissionGenerations: [String: UInt64] = [:]
    /// A phone that was never removed is at generation 0, not nil.
    private func admissionGeneration(_ phoneDeviceID: String) -> UInt64 { admissionGenerations[phoneDeviceID] ?? 0 }
    var ask: (MobileHostPairRequest, String) async -> PromptResult = PhoneAdmission.askOnThisMac
    var dismissAsk: @MainActor (MobileHostPairRequest, String) -> Void = PhoneAdmission.dismissOnThisMac
    var accountName: @MainActor () -> String = { "" }
    var announce: @MainActor (MobileHostPairRequest) -> Void = { _ in }
    var quiet: @MainActor () -> Void = {}
    var now: () -> ContinuousClock.Instant = { .now }
    /// The serving period (``PhoneAccessGate/servingPeriod``): nil while Phone Access is off,
    /// and an answer saves only within the period its question opened in.
    var servingPeriod: @Sendable () -> UInt64? = { 0 }

    init(phones: MobileHostPairedStore, disconnect: @escaping @Sendable (String) async -> Void) {
        self.phones = phones
        generation = phones.generation
        phones.observe { [weak self] change in
            // task-owner: bounded reconciliation for one store event; the store is app-lived
            Task { @MainActor [weak self] in
                guard let self else { return }
                if generation != self.phones.generation {
                    generation = self.phones.generation
                    denied = [:]
                    // Only questions asked under an earlier account; one asked since the switch stays.
                    cancelQuestions { $0.accountGeneration != self.phones.generation }
                    if questions.isEmpty {
                        for dialog in CmuxDialogCenter.shared.records where dialog.spec.identifier == Self.dialogIdentifier {
                            CmuxDialogCenter.shared.dismiss(dialog.id)
                        }
                    }
                }
                // An account switch is settled above, and the listener restarts for the new account.
                guard !change.switchedAccount else { return }
                for phone in change.removed where phone.transport == .iroh {
                    // A removal belongs to its own account: stop once another account is selected,
                    // including while a disconnect is suspended.
                    guard self.phones.generation == change.generation else { return }
                    remove(phoneDeviceID: phone.id)
                    denied[phone.id] = nil
                    await disconnect(phone.id)
                }
            }
        }
    }

    func decide(_ phone: MobileHostPairRequest) async -> Bool {
        guard phone.transport == .iroh, let period = servingPeriod(), let user = phones.current?.userID else { return false }
        let selectedAccountGeneration = phones.generation
        let selectedAdmissionGeneration = admissionGeneration(phone.phoneDeviceID)
        if phones.trusts(phone) { return true }
        if let at = denied[phone.phoneDeviceID], at.duration(to: now()) < .seconds(600), generation == selectedAccountGeneration { return false }
        let question: Question
        if let existing = questions[phone.phoneDeviceID] {
            guard existing.accountGeneration == selectedAccountGeneration,
                  existing.admissionGeneration == selectedAdmissionGeneration, existing.servingPeriod == period else { return false }
            question = existing
        } else {
            guard questions.count < 2 else { return false }
            announce(phone)
            // task-owner: one question and save per endpoint, shared by concurrent connections
            let waiter = PromptWaiter()
            let account = accountName().isEmpty ? user : accountName()
            let id = UUID()
            let task = Task { [self, waiter] in
                let answer = await waiter.wait { await self.ask(phone, account) }
                guard !Task.isCancelled, servingPeriod() == period, admissionGeneration(phone.phoneDeviceID) == selectedAdmissionGeneration,
                      phones.generation == selectedAccountGeneration, phones.current?.userID == user else { return false }
                switch answer {
                case .unavailable: return false
                case .deny: denied[phone.phoneDeviceID] = now(); return false
                case .allow: break
                }
                do {
                    let at = Date()
                    // The edit runs later on the store's queue; a period that ended meanwhile saves nothing.
                    try await phones.change(for: user, generation: selectedAccountGeneration) { [servingPeriod] devices in
                        guard servingPeriod() == period else { return }
                        devices.approve(phone, at: at)
                    }
                    return servingPeriod() == period && admissionGeneration(phone.phoneDeviceID) == selectedAdmissionGeneration &&
                        phones.generation == selectedAccountGeneration && phones.trusts(phone)
                } catch { return false }
            }
            question = Question(id: id, accountGeneration: selectedAccountGeneration,
                                admissionGeneration: selectedAdmissionGeneration, servingPeriod: period, task: task,
                                cancel: { [self, waiter] in
                                    waiter.finish(.unavailable)
                                    dismissAsk(phone, account)
                                })
            questions[phone.phoneDeviceID] = question
        }
        let allowed = await question.task.value
        if questions[phone.phoneDeviceID]?.id == question.id {
            questions[phone.phoneDeviceID] = nil
            if questions.isEmpty { quiet() }
        }
        return allowed && servingPeriod() == period && admissionGeneration(phone.phoneDeviceID) == selectedAdmissionGeneration &&
            phones.generation == selectedAccountGeneration && phones.trusts(phone)
    }

    /// Removes a phone's pending question before the store forget is queued. The
    /// waiter resolves as unavailable, and a late Allow cannot pass the new token.
    func remove(phoneDeviceID: String) {
        admissionGenerations[phoneDeviceID, default: 0] &+= 1
        denied[phoneDeviceID] = nil
        guard let question = questions.removeValue(forKey: phoneDeviceID) else { return }
        question.cancel()
        question.task.cancel()
        if questions.isEmpty { quiet() }
    }

    /// Phone Access was turned off or signed out: every question from a period that has
    /// ended resolves as unavailable, and a late Allow cannot pass its phone's new token.
    /// A cancellation that arrives after Phone Access came back on leaves the new period's.
    func cancelAll() {
        let current = servingPeriod()
        cancelQuestions { $0.servingPeriod != current }
    }

    private func cancelQuestions(where stale: (Question) -> Bool) {
        let ended = questions.filter { stale($0.value) }
        guard !ended.isEmpty else { return }
        for (phoneDeviceID, question) in ended {
            admissionGenerations[phoneDeviceID, default: 0] &+= 1
            questions[phoneDeviceID] = nil
            question.cancel()
            question.task.cancel()
        }
        if questions.isEmpty { quiet() }
    }

    static func spec(_ phone: MobileHostPairRequest, user: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: IPhoneHostStrings.phoneAccessTitle(phone.name, key: phone.shortFingerprint),
                       lines: [IPhoneHostStrings.signedInAs(user), IPhoneHostStrings.irohAdmissionBody, IPhoneHostStrings.pairKey(phone.identityKey)],
                       buttons: [.cancel(), CmuxDialogButton(id: "deny", title: IPhoneHostStrings.pairDeny),
                                 CmuxDialogButton(id: "allow", title: IPhoneHostStrings.pairAllow)],
                       identifier: dialogIdentifier)
    }

    static func askOnThisMac(_ phone: MobileHostPairRequest, user: String) async -> PromptResult {
        await askOnThisMac(phone, user: user, timeout: .seconds(120))
    }

    @MainActor
    static func dismissOnThisMac(_ phone: MobileHostPairRequest, _ user: String) {
        let prompt = spec(phone, user: user)
        for record in CmuxDialogCenter.shared.records where record.spec == prompt {
            CmuxDialogCenter.shared.dismiss(record.id)
        }
    }

    static func askOnThisMac(_ phone: MobileHostPairRequest, user: String, timeout: Duration,
                             center: CmuxDialogCenter = .shared,
                             keyWindow: @MainActor () -> NSWindow? = { NSApp?.keyWindow }) async -> PromptResult {
        return await withCheckedContinuation { continuation in
            let timer = DemandTimer(owner: "PhoneAdmission.question")
            let scope: CmuxDialogScope = if let window = keyWindow(), window.isVisible, !window.isMiniaturized {
                .window(window)
            } else {
                .app
            }
            let id = center.present(spec(phone, user: user), in: scope) { answer in
                timer.cancel()
                if answer.isDismissal {
                    continuation.resume(returning: .unavailable)
                } else if answer.button == "allow" {
                    continuation.resume(returning: .allow)
                } else if answer.button == "deny" {
                    // Only the explicit Don't Allow button starts the denial cooldown.
                    continuation.resume(returning: .deny)
                } else {
                    // Escape and Command-period press Cancel without recording a denial.
                    continuation.resume(returning: .unavailable)
                }
            }
            timer.schedule(after: timeout) { @MainActor in center.dismiss(id) }
        }
    }
}

extension IPhoneHostService {
    public static var phoneAccessDialogIdentifier: String { PhoneAdmission.dialogIdentifier }
    /// The composition root joins the two phone transports without an import cycle.
    public func followPhoneAccess(_ gate: PhoneAccessGate, disconnect: @escaping @Sendable (String) async -> Void) {
        guard phoneAdmission == nil else { return }
        let admission = PhoneAdmission(phones: pairedStore, disconnect: disconnect)
        admission.accountName = { [weak self] in self?.account?.email ?? self?.account?.userID ?? "" }
        admission.announce = { [weak self] request in self?.announcePhoneAccess(request) }
        admission.quiet = { [weak self] in self?.quietAttention() }
        admission.servingPeriod = { gate.servingPeriod }
        phoneAdmission = admission
        gate.setAdmission(decide: { await admission.decide($0) }, recheck: { [pairedStore] in pairedStore.trusts($0) },
                          cancel: { await admission.cancelAll() })
    }

    func announcePhoneAccess(_ request: MobileHostPairRequest) {
        let name = request.name.isEmpty ? IPhoneHostStrings.unnamedPhone : request.name
        let body = account.map { IPhoneHostStrings.signedInAs($0.email ?? $0.userID) } ?? ""
        pairNotices?.post(IPhoneHostStrings.noticeTitle(name), body)
        if let app = NSApp, !app.isActive, !WindowDrawPolicy.isAutomationLaunch(ProcessInfo.processInfo.environment) {
            if let attentionRequest { app.cancelUserAttentionRequest(attentionRequest) }
            attentionRequest = app.requestUserAttention(.criticalRequest)
        }
    }
}
