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
    static let dialogIdentifier = "cmux.dialog.phoneAccessAllow"
    private let phones: MobileHostPairedStore
    private var questions: [String: (id: UUID, generation: UInt64, task: Task<Bool, Never>)] = [:]
    private var denied: [String: ContinuousClock.Instant] = [:]
    private var generation: UInt64
    var ask: (MobileHostPairRequest, String) async -> PromptResult = PhoneAdmission.askOnThisMac
    var accountName: @MainActor () -> String = { "" }
    var announce: @MainActor (MobileHostPairRequest) -> Void = { _ in }
    var quiet: @MainActor () -> Void = {}
    var now: () -> ContinuousClock.Instant = { .now }

    init(phones: MobileHostPairedStore, disconnect: @escaping @Sendable (String) async -> Void) {
        self.phones = phones
        generation = phones.generation
        phones.observe { [weak self] change in
            // task-owner: bounded reconciliation for one store event; the store is app-lived
            Task { @MainActor [weak self] in
                guard let self else { return }
                if generation != self.phones.generation {
                    generation = self.phones.generation
                    for question in questions.values { question.task.cancel() }
                    questions = [:]
                    denied = [:]
                    for dialog in CmuxDialogCenter.shared.records where dialog.spec.identifier == Self.dialogIdentifier {
                        CmuxDialogCenter.shared.dismiss(dialog.id)
                    }
                }
                for phone in change.removed where phone.transport == .iroh {
                    denied[phone.id] = nil
                    await disconnect(phone.id)
                }
            }
        }
    }

    func decide(_ phone: MobileHostPairRequest) async -> Bool {
        guard phone.transport == .iroh, let user = phones.current?.userID else { return false }
        let selected = phones.generation
        if phones.trusts(phone) { return true }
        if let at = denied[phone.phoneDeviceID], at.duration(to: now()) < .seconds(600), generation == selected { return false }
        let question: (id: UUID, generation: UInt64, task: Task<Bool, Never>)
        if let existing = questions[phone.phoneDeviceID] {
            guard existing.generation == selected else { return false }
            question = existing
        } else {
            guard questions.count < 2 else { return false }
            announce(phone)
            // task-owner: one question and save per endpoint, shared by concurrent connections
            question = (UUID(), selected, Task { [self] in
                let answer = await ask(phone, accountName().isEmpty ? user : accountName())
                if questions.count == 1 { quiet() }
                guard !Task.isCancelled, phones.generation == selected, phones.current?.userID == user else { return false }
                switch answer {
                case .unavailable: return false
                case .deny: denied[phone.phoneDeviceID] = now(); return false
                case .allow: break
                }
                do {
                    try await phones.change(for: user, generation: selected) { $0.approve(phone, at: Date()) }
                    return phones.generation == selected && phones.trusts(phone)
                } catch { return false }
            })
            questions[phone.phoneDeviceID] = question
        }
        let allowed = await question.task.value
        if questions[phone.phoneDeviceID]?.id == question.id { questions[phone.phoneDeviceID] = nil }
        return allowed && phones.generation == selected && phones.trusts(phone)
    }

    static func spec(_ phone: MobileHostPairRequest, user: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: IPhoneHostStrings.phoneAccessTitle(phone.name),
                       lines: [IPhoneHostStrings.signedInAs(user), IPhoneHostStrings.irohAdmissionBody, IPhoneHostStrings.pairKey(phone.identityKey)],
                       buttons: [CmuxDialogButton(id: "deny", title: IPhoneHostStrings.pairDeny, role: .cancel),
                                 CmuxDialogButton(id: "allow", title: IPhoneHostStrings.pairAllow)],
                       identifier: dialogIdentifier)
    }

    static func askOnThisMac(_ phone: MobileHostPairRequest, user: String) async -> PromptResult {
        await askOnThisMac(phone, user: user, timeout: .seconds(120))
    }

    static func askOnThisMac(_ phone: MobileHostPairRequest, user: String, timeout: Duration) async -> PromptResult {
        return await withCheckedContinuation { continuation in
            let timer = DemandTimer(owner: "PhoneAdmission.question")
            let scope: CmuxDialogScope = if let window = NSApp?.keyWindow, window.isVisible, !window.isMiniaturized {
                .window(window)
            } else {
                .app
            }
            let id = CmuxDialogCenter.shared.present(spec(phone, user: user), in: scope) { answer in
                timer.cancel()
                if answer.isDismissal {
                    continuation.resume(returning: .unavailable)
                } else if answer.button == "allow" {
                    continuation.resume(returning: .allow)
                } else {
                    continuation.resume(returning: .deny)
                }
            }
            timer.schedule(after: timeout) { @MainActor in CmuxDialogCenter.shared.dismiss(id) }
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
        phoneAdmission = admission
        gate.setAdmission(decide: { await admission.decide($0) }, recheck: { [pairedStore] in pairedStore.trusts($0) })
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
