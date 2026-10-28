public import CmuxNextDesign
public import Foundation

/// The question before cmux runs a script or an executable file another app
/// opened with it (`ExternalOpenRoute.confirmRun`), and the refusal for one
/// macOS marked as downloaded. Nothing runs until the person presses Run: the
/// open itself came from another app. Cancel is the Escape button and has
/// the keyboard first; Run has no Return key, so a key typed for the app the
/// open came from cannot run the file. A downloaded file gets no Run button,
/// and no answer runs it.
@MainActor
public struct OpenedScriptConfirmation {
    public static let runButton = "run"
    public static let showInFinderButton = "show-in-finder"
    public static let identifier = "cmux.dialog.openedScript"
    public static let refusalIdentifier = "cmux.dialog.openedScriptRefused"

    /// The opened file, its folder (the terminal's cwd) and the shell-quoted command.
    public var path: String
    public var cwd: String
    public var command: String
    /// The file carries `com.apple.quarantine`: refused, never run.
    public var quarantined: Bool

    public init(path: String, cwd: String, command: String, quarantined: Bool) {
        self.path = path
        self.cwd = cwd
        self.command = command
        self.quarantined = quarantined
    }

    public var fileName: String { (path as NSString).lastPathComponent }

    public var spec: CmuxDialogSpec {
        if quarantined {
            return CmuxDialogSpec(
                title: OpenedScriptStrings.refusedTitle(fileName),
                lines: [OpenedScriptStrings.refusedBody, path],
                buttons: [
                    CmuxDialogButton(id: Self.showInFinderButton, title: OpenedScriptStrings.showInFinder, key: "r"),
                    .ok(),
                ],
                identifier: Self.refusalIdentifier
            )
        }
        return CmuxDialogSpec(
            title: OpenedScriptStrings.runTitle(fileName),
            lines: [OpenedScriptStrings.runBody, path],
            buttons: [
                .cancel(),
                CmuxDialogButton(id: Self.runButton, title: OpenedScriptStrings.run, role: .destructive),
            ],
            identifier: Self.identifier
        )
    }

    /// Shows ``spec`` through `present` and acts on its one answer: Run (only
    /// for a file not quarantined) calls `run` with the folder and the command
    /// line to type; Show in Finder calls `reveal`. Any other answer, a
    /// dismissal included, does nothing.
    public func ask(present: (CmuxDialogSpec, @escaping (CmuxDialogAnswer) -> Void) -> Void,
                    run: @escaping (_ cwd: String, _ typing: String) -> Void,
                    reveal: @escaping (URL) -> Void) {
        let request = self
        present(spec) { answer in
            guard !answer.isDismissal else { return }
            switch answer.button {
            case Self.runButton where !request.quarantined: run(request.cwd, request.command + "\n")
            case Self.showInFinderButton: reveal(URL(fileURLWithPath: request.path))
            default: return
            }
        }
    }
}

/// The opened-file run question's strings (this module's `Localizable` table).
nonisolated enum OpenedScriptStrings {
    static func runTitle(_ name: String) -> String {
        String(localized: "openedScript.run.title", defaultValue: "Run “\(name)”?", bundle: .module)
    }

    static var runBody: String {
        String(localized: "openedScript.run.body", defaultValue: "cmux will run this file in a new terminal tab. Run only files you trust.",
               bundle: .module)
    }

    static var run: String {
        String(localized: "openedScript.run.button", defaultValue: "Run", bundle: .module)
    }

    static func refusedTitle(_ name: String) -> String {
        String(localized: "openedScript.refused.title", defaultValue: "cmux will not run “\(name)”", bundle: .module)
    }

    static var refusedBody: String {
        String(localized: "openedScript.refused.body", defaultValue: "This file was downloaded from the internet. cmux does not run downloaded files.",
               bundle: .module)
    }

    static var showInFinder: String {
        String(localized: "openedScript.refused.showInFinder", defaultValue: "Show in Finder", bundle: .module)
    }
}
