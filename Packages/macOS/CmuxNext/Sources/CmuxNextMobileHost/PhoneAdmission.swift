import AppKit
import CmuxNextDesign
import CmuxNextMobile
import CmuxNextWakeups
import Foundation

/// Local admission for the separately served Phone Access link. Always Ask: only a
/// person on this Mac may persist its TLS-proved endpoint in the shared phone list.
@MainActor
final class PhoneAdmission {
    static let dialogIdentifier = "cmux.dialog.phoneAccessAllow"
    private let phones: MobileHostPairedStore
    private var questions: [String: (id: UUID, generation: UInt64, task: Task<Bool, Never>)] = [:]
    private var denied: [String: ContinuousClock.Instant] = [:]
    private var generation: UInt64
    var ask: (MobileHostPairRequest, String) async -> Bool = PhoneAdmission.askOnThisMac
    var now: () -> ContinuousClock.Instant = { .now }

    init(phones: MobileHostPairedStore, disconnect: @escaping @Sendable (String) async -> Void) {
        self.phones = phones
        generation = phones.generation
        phones.observe { [weak self] change in
            // task-owner: bounded reconciliation for one store event; the store is app-lived
            Task { @MainActor [weak self] in
                guard let self else { return }
                if generation != phones.generation {
                    generation = phones.generation
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
            // task-owner: one question and save per endpoint, shared by concurrent connections
            question = (UUID(), selected, Task { [self] in
                let allowed = await ask(phone, user)
                guard !Task.isCancelled, phones.generation == selected, phones.current?.userID == user else { return false }
                guard allowed else { denied[phone.phoneDeviceID] = now(); return false }
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
        CmuxDialogSpec(title: IPhoneHostStrings.pairTitle(phone.name),
                       lines: [IPhoneHostStrings.signedInAs(user), IPhoneHostStrings.irohAdmissionBody, IPhoneHostStrings.pairKey(phone.identityKey)],
                       buttons: [CmuxDialogButton(id: "deny", title: IPhoneHostStrings.pairDeny, role: .cancel),
                                 CmuxDialogButton(id: "allow", title: IPhoneHostStrings.pairAllow)],
                       identifier: dialogIdentifier)
    }

    private static func askOnThisMac(_ phone: MobileHostPairRequest, user: String) async -> Bool {
        guard let window = NSApp?.keyWindow, window.isVisible, !window.isMiniaturized else { return false }
        return await withCheckedContinuation { continuation in
            let timer = DemandTimer(owner: "PhoneAdmission.question")
            let id = CmuxDialogCenter.shared.present(spec(phone, user: user), in: .window(window)) { answer in
                timer.cancel()
                continuation.resume(returning: !answer.isDismissal && answer.button == "allow")
            }
            timer.schedule(after: .seconds(120)) { @MainActor in CmuxDialogCenter.shared.dismiss(id) }
        }
    }
}

extension IPhoneHostService {
    public static var phoneAccessDialogIdentifier: String { PhoneAdmission.dialogIdentifier }
    /// The composition root joins the two phone transports without an import cycle.
    public func followPhoneAccess(_ gate: PhoneAccessGate, disconnect: @escaping @Sendable (String) async -> Void) {
        guard phoneAdmission == nil else { return }
        let admission = PhoneAdmission(phones: pairedStore, disconnect: disconnect)
        phoneAdmission = admission
        gate.setAdmission(decide: { await admission.decide($0) }, recheck: { [pairedStore] in pairedStore.trusts($0) })
    }
}
