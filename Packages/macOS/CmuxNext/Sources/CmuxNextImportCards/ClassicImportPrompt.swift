public import CmuxNextDaemon
public import CmuxNextDesign
import CmuxNextImportSuggestions
import Foundation

/// The prompt every classic import shows before anything is restored: what this exact snapshot brings, in
/// sentences (``ClassicImportPreviewStrings``), on the app's own dialog card.
public enum ClassicImportPrompt {
    public static let importButton = "import"
    public static let identifier = "cmux.dialog.classicImport"

    /// The prompt for `preview`; `atLaunch`, the launch's own ask: it says where the import waits and its
    /// Cancel reads Not Now, so a Not Now needs no toast after it.
    public static func spec(_ preview: ClassicImportPreview, atLaunch: Bool) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: ClassicImportPreviewStrings.title,
            lines: lines(preview, atLaunch: atLaunch),
            buttons: [
                atLaunch ? .cancel(ClassicImportPreviewStrings.notNow) : .cancel(),
                CmuxDialogButton(id: importButton, title: ClassicImportPreviewStrings.importButton, role: .default),
            ],
            identifier: identifier
        )
    }

    public static func lines(_ preview: ClassicImportPreview, atLaunch: Bool) -> [String] {
        let counts = preview.counts
        return ClassicImportPreviewStrings.lines(
            .init(workspaces: counts.workspaces, browserTabs: counts.browserTabs, filePages: counts.localFilePages,
                  sshWorkspaces: counts.sshWorkspaces, agentChats: counts.agentChats, skippedCloudVMs: counts.skippedCloudVMs,
                  cleanup: counts.cleanupWorkspaces),
            app: ClassicImportPreviewStrings.appName(preview.bundleID), savedAt: Date(timeIntervalSince1970: preview.savedAt),
            classicRunning: preview.classicRunning, atLaunch: atLaunch)
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The classic import prompt and its after-Not Now toast as the debug gallery shows them (Leo 2026-11-15, on
/// his NIGHTLY's preview: "this is kinda strange. what happened here?", and on the toast after Cancel: "the
/// styling for that + this is just kinda awkward"). `debug.dialog {open: "classicImport…"}` opens a prompt,
/// `debug.toast {classic_toast: "…"}` shows a toast. The landed prompt uses the shipping strings; `Before` and
/// the other variants are the looks compared, in English only (they never ship).
public enum ClassicImportPromptGallery {
    /// What Leo's NIGHTLY found: 8 workspaces, 2 browser tabs and 1 agent chat, saved today at 1:47 PM.
    public static var leoPreview: ClassicImportPreview {
        ClassicImportPreview(counts: ClassicImportReply.Preview(workspaces: 8, browserTabs: 2, agentChats: 1),
                             bundleID: "com.cmuxterm.app", savedAt: todayAt(hour: 13, minute: 47), classicRunning: false)
    }

    /// Every caution at once: classic still open, Cloud VM workspaces left, an interrupted run's workspaces replaced.
    public static var cautionsPreview: ClassicImportPreview {
        ClassicImportPreview(counts: ClassicImportReply.Preview(workspaces: 12, skippedCloudVMs: 2, cleanupWorkspaces: 3, browserTabs: 5,
                                                                localFilePages: 1, sshWorkspaces: 2, agentChats: 4),
                             bundleID: "com.cmuxterm.app.nightly", savedAt: todayAt(hour: 9, minute: 5), classicRunning: true)
    }

    private static func todayAt(hour: Int, minute: Int) -> Double {
        (Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()).timeIntervalSince1970
    }

    public static var dialogs: [String: CmuxDialogSpec] {
        let importButton = CmuxDialogButton(id: ClassicImportPrompt.importButton, title: "Import", role: .default)
        let saved = Date(timeIntervalSince1970: leoPreview.savedAt).formatted(date: .abbreviated, time: .shortened)
        return [
            // Landed: sentences, zero counts hidden, cautions only when they apply.
            "classicImport": ClassicImportPrompt.spec(leoPreview, atLaunch: true),
            "classicImportManual": ClassicImportPrompt.spec(leoPreview, atLaunch: false),
            "classicImportCautions": ClassicImportPrompt.spec(cautionsPreview, atLaunch: true),
            // What Leo saw on 2026-11-15.
            "classicImportBefore": CmuxDialogSpec(
                title: "Import these classic workspaces?",
                lines: ["Source: cmux (classic), saved \(saved)", "Workspaces: 8", "Browser tabs: 2", "Local file pages: 0",
                        "SSH workspaces: 0", "Agent chats: 1", "Cloud VM workspaces skipped: 0",
                        "Importing loads saved browser pages, connects to saved SSH hosts, and resumes saved agent chats.",
                        "Interrupted workspaces to replace (their terminals will end): 0"],
                buttons: [.cancel(), importButton], identifier: ClassicImportPrompt.identifier),
            // Variant: the headline number in the title, the rest one line under it.
            "classicImportCountTitle": CmuxDialogSpec(
                title: "Import 8 workspaces from classic cmux?",
                lines: ["With 2 browser tabs and 1 agent chat, as cmux saved them today at 1:47 PM.",
                        "Pages load and the agent chat resumes where it left off.",
                        "You can import them later from Settings › Import."],
                buttons: [.cancel("Not Now"), importButton], identifier: ClassicImportPrompt.identifier),
            // Variant: a short list of what comes over, nonzero rows only.
            "classicImportList": CmuxDialogSpec(
                title: "Import from classic cmux?",
                lines: ["cmux saved these today at 1:47 PM:", "•  8 workspaces", "•  2 browser tabs", "•  1 agent chat",
                        "They open exactly as saved: pages load and the agent chat resumes."],
                buttons: [.cancel("Not Now"), importButton], identifier: ClassicImportPrompt.identifier),
        ]
    }

    /// The toast after Cancel, by variant: `before` (what Leo saw), `short` (one line, the way back in the
    /// tooltip), `action` (one line and an Import button that asks again). `none` (no toast) is the landed
    /// look: the prompt itself says where the import waits.
    public static let toasts: [String: CmuxToast] = [
        "before": CmuxToast(id: "classicImport", message: "Classic workspaces stay in classic cmux. Import them any time from Settings › Import."),
        "short": CmuxToast(id: "classicImport", message: "Classic workspaces stay in classic cmux.",
                           detail: "Import them any time from Settings › Import."),
        "action": CmuxToast(id: "classicImport", message: "Classic workspaces weren’t imported.", action: CmuxToast.Action(title: "Import…")),
    ]
}
#endif
