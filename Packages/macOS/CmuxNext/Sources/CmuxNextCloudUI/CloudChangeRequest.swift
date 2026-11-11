public import AppKit
public import CmuxNextDesign

/// The person's yes before a Cloud machine change an agent or a script asked for (resize, snapshot,
/// template, restore, snapshot delete), as a create's request asks first. cmux-platform holds such a
/// change for a person's approval; the App sends it only as the person's own, through the approval
/// loop, so nothing is sent until they click Allow. The App lists ``identifier`` as user-only
/// (DebugDialog), so automation never answers it. Keys live in Resources/Cloud.xcstrings with every app locale.
public struct CloudChangeRequest {
    /// The machine's name, when the change has one.
    public var machine: String?
    /// The change's arguments as the agent or script asked them (`size: large`), shown so the person sees what they allow.
    public var asked: [String: String]

    public init(machine: String? = nil, asked: [String: String] = [:]) {
        self.machine = machine
        self.asked = asked
    }

    public static let identifier = "cmux.dialog.cloud.changeRequest"
    /// The id of the button that says yes.
    public static let accept = "allow"

    /// `title`: the asked action's own name (its palette title).
    public func spec(_ title: String) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: title,
            lines: [String(localized: "cloud.changeRequest.body", defaultValue: "Asked by an agent or a script. A Cloud machine change can count against your Cloud plan.", table: "Cloud", bundle: .module)]
                + (machine.map { [String(format: String(localized: "cloud.changeRequest.machine", defaultValue: "Machine: %@", table: "Cloud", bundle: .module), $0)] } ?? [])
                + asked.keys.sorted().map { "\($0): \(asked[$0] ?? "")" },
            buttons: [.cancel(String(localized: "cloud.changeRequest.decline", defaultValue: "Don't Allow", table: "Cloud", bundle: .module)),
                      CmuxDialogButton(id: Self.accept, title: String(localized: "cloud.changeRequest.accept", defaultValue: "Allow", table: "Cloud", bundle: .module), role: .default)],
            identifier: Self.identifier)
    }

    /// True only for the person's click on Allow; no window answers false.
    @MainActor public func allowed(_ title: String, in window: NSWindow?) async -> Bool {
        guard let window else { return false }
        return await CmuxDialogCenter.shared.present(spec(title), in: .window(window)).button == Self.accept
    }

    /// ``allowed(_:in:)`` that also tells `shown` the dialog's id (CmuxDialogCenter's, as `cmux debug dialog`
    /// lists it) as soon as it is shown, so an agent's or a script's run can answer that it waits for the person.
    @MainActor public func allowed(_ title: String, in window: NSWindow?, shown: @escaping @MainActor (Int) -> Void) async -> Bool {
        guard let window else { return false }
        let spec = spec(title)
        return await withCheckedContinuation { continuation in
            let id = CmuxDialogCenter.shared.present(spec, in: .window(window)) { answer in
                continuation.resume(returning: answer.button == Self.accept)
            }
            shown(id)
        }
    }

    /// The yes a change waits for: a person's own run (`person`) is theirs; an agent's or a script's asks in the window
    /// `window` answers when it runs (``allowed(_:in:shown:)``, `shown` told the dialog's id; without it ``allowed(_:in:)``).
    public func asking(_ title: String, person: Bool, in window: @escaping @MainActor () -> NSWindow?,
                       shown: (@MainActor (Int) -> Void)? = nil) -> @MainActor () async -> Bool {
        { person ? true : await shown.map { allowed(title, in: window(), shown: $0) } ?? allowed(title, in: window()) }
    }

    /// What an agent's or a script's run answers when the person chose Don't Allow.
    public static var declined: String {
        String(localized: "cloud.changeRequest.declined", defaultValue: "Don't Allow was chosen in the cmux window; nothing changed.", table: "Cloud", bundle: .module)
    }
}
