public import AppKit
public import CmuxNextDaemon
public import CmuxNextDesign
public import CmuxNextOnboarding
import CmuxNextImportSuggestions
import Foundation

/// The prompt every classic import shows before anything is restored: what the person is authorizing, in
/// sentences (``ClassicImportPreviewStrings``), on the app's own dialog card.
extension ClassicImportPreview {
    public static let importButton = "import"
    public static let dialogIdentifier = "cmux.dialog.classicImport"

    /// The prompt; `atLaunch`, the launch's own ask: it says where the import waits and its Cancel reads Not Now.
    public func dialogSpec(atLaunch: Bool) -> CmuxDialogSpec {
        CmuxDialogSpec(usesTransientMaterial: true,
            title: counts == nil ? ClassicImportPreviewStrings.consentTitle : ClassicImportPreviewStrings.title,
            lines: promptLines(atLaunch: atLaunch),
            buttons: [
                atLaunch ? .cancel(ClassicImportPreviewStrings.notNow) : .cancel(),
                CmuxDialogButton(id: Self.importButton, title: ClassicImportPreviewStrings.importButton, role: .default),
            ],
            identifier: Self.dialogIdentifier
        )
    }

    /// The Set Up cmux card's cmux Classic row for this preview: what the dialog says, as the row's facts. Nil
    /// before the person consents to the read (no `counts`): the consent dialog asks, not the row.
    public var setupOffer: FirstRunSetup.ClassicOffer? {
        guard let counts else { return nil }
        return FirstRunSetup.ClassicOffer(workspaces: counts.workspaces, app: ClassicImportPreviewStrings.appName(bundleID), savedAt: savedAt,
                                   running: classicRunning, browserTabs: counts.browserTabs, sshWorkspaces: counts.sshWorkspaces,
                                   agentChats: counts.agentChats)
    }

    public func promptLines(atLaunch: Bool) -> [String] {
        guard let counts else {
            var lines = [ClassicImportPreviewStrings.consentData, ClassicImportPreviewStrings.consentEffects]
            if atLaunch { lines.append(ClassicImportPreviewStrings.later) }
            return lines
        }
        return ClassicImportPreviewStrings(workspaces: counts.workspaces, browserTabs: counts.browserTabs, filePages: counts.localFilePages,
                                    sshWorkspaces: counts.sshWorkspaces, agentChats: counts.agentChats,
                                    skippedCloudVMs: counts.skippedCloudVMs, cleanup: counts.cleanupWorkspaces)
            .lines(app: ClassicImportPreviewStrings.appName(bundleID), savedAt: Date(timeIntervalSince1970: savedAt),
                   classicRunning: classicRunning, atLaunch: atLaunch)
    }
}

extension CmuxToastCenter {
    /// The classic import's toast; `importAgain` adds Import… (after the launch's Not Now: one short line and a
    /// button, never two sentences beside Don't Show Again; Leo 2026-11-15: "the styling for that + this is just
    /// kinda awkward"), which runs it.
    @MainActor public func showClassicImport(_ message: String, in window: NSWindow, importAgain: (() -> Void)? = nil) {
        let action = importAgain.map { _ in CmuxToast.Action(title: ClassicImportPreviewStrings.importAgain) }
        let handle = show(CmuxToast(id: "classicImport", message: message, action: action), in: window)
        if let importAgain { handle.onAction = importAgain }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The classic import prompt and its after-Not Now toast as the debug gallery shows them (Leo 2026-11-15, on
/// his NIGHTLY's preview: "this is kinda strange. what happened here?", and on the toast after Cancel: "the
/// styling for that + this is just kinda awkward"). `debug.dialog {open: "classicImport…"}` opens a prompt,
/// `debug.toast {classic_toast: "…"}` shows a toast. The landed prompt uses the shipping strings; `Before` and
/// the other variants are the looks compared, in English only (they never ship).
extension ClassicImportPreview {
    /// What Leo's NIGHTLY found: 8 workspaces, 2 browser tabs and 1 agent chat, saved today at 1:47 PM.
    public static var leoGallery: ClassicImportPreview {
        ClassicImportPreview(counts: ClassicImportReply.Preview(workspaces: 8, browserTabs: 2, agentChats: 1),
                             bundleID: "com.cmuxterm.app", savedAt: todayAt(hour: 13, minute: 47), classicRunning: false)
    }

    /// Every caution at once: classic still open, Cloud VM workspaces left, an interrupted run's workspaces replaced.
    public static var cautionsGallery: ClassicImportPreview {
        ClassicImportPreview(counts: ClassicImportReply.Preview(workspaces: 12, skippedCloudVMs: 2, cleanupWorkspaces: 3, browserTabs: 5,
                                                                localFilePages: 1, sshWorkspaces: 2, agentChats: 4),
                             bundleID: "com.cmuxterm.app.nightly", savedAt: todayAt(hour: 9, minute: 5), classicRunning: true)
    }

    private static func todayAt(hour: Int, minute: Int) -> Double {
        (Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()).timeIntervalSince1970
    }
}

extension CmuxDialogSpec {
    public static var classicImportGallery: [String: CmuxDialogSpec] {
        let leo = ClassicImportPreview.leoGallery, identifier = ClassicImportPreview.dialogIdentifier
        let consent = ClassicImportPreview(counts: nil, bundleID: leo.bundleID, savedAt: 0, classicRunning: false)
        let importButton = CmuxDialogButton(id: ClassicImportPreview.importButton, title: "Import", role: .default)
        let saved = Date(timeIntervalSince1970: leo.savedAt).formatted(date: .abbreviated, time: .shortened)
        return [
            // The shipping prompts can be shown before opening any Classic file.
            "classicImport": consent.dialogSpec(atLaunch: true),
            "classicImportManual": consent.dialogSpec(atLaunch: false),
            "classicImportCautions": ClassicImportPreview.cautionsGallery.dialogSpec(atLaunch: true),
            // What Leo saw on 2026-11-15.
            "classicImportBefore": CmuxDialogSpec(
                title: "Import these classic workspaces?",
                lines: ["Source: cmux (classic), saved \(saved)", "Workspaces: 8", "Browser tabs: 2", "Local file pages: 0",
                        "SSH workspaces: 0", "Agent chats: 1", "Cloud VM workspaces skipped: 0",
                        "Importing loads saved browser pages, connects to saved SSH hosts, and resumes saved agent chats.",
                        "Interrupted workspaces to replace (their terminals will end): 0"],
                buttons: [.cancel(), importButton], identifier: identifier),
            // Variant: the headline number in the title, the rest one line under it.
            "classicImportCountTitle": CmuxDialogSpec(
                title: "Import 8 workspaces from classic cmux?",
                lines: ["With 2 browser tabs and 1 agent chat, as cmux saved them today at 1:47 PM.",
                        "Pages load and the agent chat resumes where it left off.",
                        "You can import them later from Settings › Import."],
                buttons: [.cancel("Not Now"), importButton], identifier: identifier),
            // Variant: a short list of what comes over, nonzero rows only.
            "classicImportList": CmuxDialogSpec(
                title: "Import from classic cmux?",
                lines: ["cmux saved these today at 1:47 PM:", "•  8 workspaces", "•  2 browser tabs", "•  1 agent chat",
                        "They open exactly as saved: pages load and the agent chat resumes."],
                buttons: [.cancel("Not Now"), importButton], identifier: identifier),
        ]
    }

}

extension CmuxToast {
    /// The toast after Not Now, by variant: `before` (what Leo saw), `short` (one line, the way back in the
    /// tooltip), `action` (one line and Import…, which asks again: the landed look).
    public static let classicImportGallery: [String: CmuxToast] = [
        "before": CmuxToast(id: "classicImport", message: "Classic workspaces stay in classic cmux. Import them any time from Settings › Import."),
        "short": CmuxToast(id: "classicImport", message: "Classic workspaces stay in classic cmux.",
                           detail: "Import them any time from Settings › Import."),
        "action": CmuxToast(id: "classicImport", message: "Classic workspaces weren’t imported.", action: CmuxToast.Action(title: "Import…")),
    ]
}
#endif
