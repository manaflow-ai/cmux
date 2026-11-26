import Foundation

public nonisolated enum HomeEngineStrings {
    static var title: String { String(localized: "home.engine.title", defaultValue: "Chief Settings", table: "Home", bundle: .localizedModule) }
    public static var pillHelp: String { String(localized: "home.engine.pillHelp", defaultValue: "Shows or hides this Chief's settings", table: "Home", bundle: .localizedModule) }
    static var openTraces: String { String(localized: "home.engine.openTraces", defaultValue: "Show Traces", table: "Home", bundle: .localizedModule) }
    static var showMemory: String { String(localized: "home.engine.showMemory", defaultValue: "Show Memory", table: "Home", bundle: .localizedModule) }
    /// The popover's link to Settings > Chief, the page with every Chief setting.
    static var allChiefSettings: String {
        String(localized: "home.engine.allChiefSettings", defaultValue: "All Chief Settings…", table: "Home", bundle: .localizedModule)
    }
    static var brainFormat: String {
        String(localized: "home.engine.brain", defaultValue: "Runs on this Mac (%@). Tools: zoom, date, spawn, tell and the harness's own.", table: "Home", bundle: .localizedModule)
    }
    /// "Runs on the paired server cmux-lawrence."
    static var runsOnServerFormat: String {
        String(localized: "home.engine.runsOnServer", defaultValue: "Runs on the paired server %@.", table: "Home", bundle: .localizedModule)
    }
    static var errorUnreachable: String {
        String(localized: "home.engine.error.unreachable", defaultValue: "The server with this Chief is not connected.", table: "Home", bundle: .localizedModule)
    }
    /// A hosted cloud Chief: the Cloud service did not answer.
    static var errorCloudUnreachable: String {
        // retry-prompt-ok: a cloud Chief's engine change goes to a paid service; the person re-sends it
        String(localized: "home.engine.error.cloudUnreachable", defaultValue: "cmux could not reach the cloud for this Chief. Check your connection and try again.", table: "Home", bundle: .localizedModule)
    }
    /// A hosted cloud Chief: no account is signed in.
    static var errorSignedOut: String {
        String(localized: "home.engine.error.signedOut", defaultValue: "Sign in to cmux to change this Chief's settings.", table: "Home", bundle: .localizedModule)
    }
    /// A hosted cloud Chief on a Cloud service that runs no Chief brains.
    static var errorCloudUnavailable: String {
        String(localized: "home.engine.error.cloudUnavailable", defaultValue: "This cloud does not run Chiefs, so this Chief does not answer.", table: "Home", bundle: .localizedModule)
    }
    /// A hosted cloud Chief's turn cannot be stopped from this Mac yet.
    static var errorCloudStopUnsupported: String {
        String(localized: "home.engine.error.cloudStopUnsupported", defaultValue: "A cloud Chief's reply cannot be stopped from here yet.", table: "Home", bundle: .localizedModule)
    }
    /// A hosted cloud Chief whose brain is turned off.
    static var hostedBrainOff: String {
        String(localized: "home.engine.hostedBrainOff", defaultValue: "This Chief is turned off, so it does not answer messages.", table: "Home", bundle: .localizedModule)
    }
    /// This Mac's Chief: its owner daemon or brain host is not running.
    static var errorLocalUnreachable: String {
        String(localized: "home.engine.error.localUnreachable", defaultValue: "This Mac's Chief is not running.", table: "Home", bundle: .localizedModule)
    }
    /// This Mac's brain was not running; the panel has just started it.
    static var errorLocalStarting: String {
        String(localized: "home.engine.error.localStarting", defaultValue: "This Mac's Chief didn't start in time, so the change wasn't saved.", table: "Home", bundle: .localizedModule)
    }
    static var errorForbidden: String {
        String(localized: "home.engine.error.forbidden", defaultValue: "This server does not let this connection change its Chief.", table: "Home", bundle: .localizedModule)
    }
    static var errorNotConfigured: String {
        String(localized: "home.engine.error.notConfigured", defaultValue: "This daemon does not reach its Chief's brain. Restart the Chief's daemon.", table: "Home", bundle: .localizedModule)
    }
    static var errorUnsupported: String {
        String(localized: "home.engine.error.unsupported", defaultValue: "This server's cmux is too old to change its Chief from here.", table: "Home", bundle: .localizedModule)
    }
    /// "The change failed: acpmux on this host has no harness x"
    static var errorRefusedFormat: String {
        String(localized: "home.engine.error.refused", defaultValue: "The change failed: %@", table: "Home", bundle: .localizedModule)
    }
    static var harness: String { String(localized: "home.engine.harness", defaultValue: "Harness", table: "Home", bundle: .localizedModule) }
    static var model: String { String(localized: "home.engine.model", defaultValue: "Model", table: "Home", bundle: .localizedModule) }
    static var effort: String { String(localized: "home.engine.effort", defaultValue: "Effort", table: "Home", bundle: .localizedModule) }
    static var speed: String { String(localized: "home.engine.speed", defaultValue: "Speed", table: "Home", bundle: .localizedModule) }
    /// The Speed row's fast tier (codex's priority processing: faster, more usage).
    static var speedFast: String { String(localized: "home.engine.speed.fast", defaultValue: "Fast", table: "Home", bundle: .localizedModule) }
    /// The Model menu's sections (``HomeChiefModelMenu``).
    static var recentSection: String { String(localized: "home.engine.models.recent", defaultValue: "Recent", table: "Home", bundle: .localizedModule) }
    static var planAndExecuteSection: String {
        String(localized: "home.engine.models.planAndExecute", defaultValue: "Plan and Execute", table: "Home", bundle: .localizedModule)
    }
    static var otherModelsSection: String {
        String(localized: "home.engine.models.other", defaultValue: "Other Models", table: "Home", bundle: .localizedModule)
    }
    static var olderModelsSection: String {
        String(localized: "home.engine.models.older", defaultValue: "Older Models", table: "Home", bundle: .localizedModule)
    }
    /// Claude Code's `opusplan`: Opus while planning, Sonnet while carrying the plan out.
    static var opusPlanTitle: String {
        String(localized: "home.engine.models.opusPlan", defaultValue: "Opus Plans, Sonnet Executes", table: "Home", bundle: .localizedModule)
    }
    /// A model's context-window variant: "Opus 5.5 · 1M context" (the model, the window).
    static var contextVariantFormat: String {
        String(localized: "home.engine.models.contextVariant", defaultValue: "%1$@ · %2$@ context", table: "Home", bundle: .localizedModule)
    }

    /// An effort level's name (the brain's ids: optchat-chief `EFFORTS`); one the app does not
    /// know shows as the brain names it.
    static func effortTitle(_ id: String) -> String {
        switch id {
        case "off": String(localized: "home.engine.effort.off", defaultValue: "Off", table: "Home", bundle: .localizedModule)
        case "minimal": String(localized: "home.engine.effort.minimal", defaultValue: "Minimal", table: "Home", bundle: .localizedModule)
        case "low": String(localized: "home.engine.effort.low", defaultValue: "Low", table: "Home", bundle: .localizedModule)
        case "medium": String(localized: "home.engine.effort.medium", defaultValue: "Medium", table: "Home", bundle: .localizedModule)
        case "high": String(localized: "home.engine.effort.high", defaultValue: "High", table: "Home", bundle: .localizedModule)
        case "xhigh": String(localized: "home.engine.effort.xhigh", defaultValue: "Extra High", table: "Home", bundle: .localizedModule)
        case "max": String(localized: "home.engine.effort.max", defaultValue: "Max", table: "Home", bundle: .localizedModule)
        default: id
        }
    }
    static var defaultValue: String { String(localized: "home.engine.default", defaultValue: "Default", table: "Home", bundle: .localizedModule) }
    /// The card's Reactions block (a416): whether a tapback can wake the Chief, and its classifier.
    static var reactionsSection: String { String(localized: "home.engine.reactions", defaultValue: "Reactions", table: "Home", bundle: .localizedModule) }
    static var reactionsCanWake: String { String(localized: "home.engine.reactions.canWake", defaultValue: "Wake Chief", table: "Home", bundle: .localizedModule) }
    static var reactionsOn: String { String(localized: "home.engine.reactions.on", defaultValue: "On", table: "Home", bundle: .localizedModule) }
    static var reactionsOff: String { String(localized: "home.engine.reactions.off", defaultValue: "Off", table: "Home", bundle: .localizedModule) }
    static var reactionClassifier: String { String(localized: "home.engine.reactions.classifier", defaultValue: "Classifier", table: "Home", bundle: .localizedModule) }
    static var reactionHarness: String { String(localized: "home.engine.reactions.harness", defaultValue: "Classifier Harness", table: "Home", bundle: .localizedModule) }
    static var reactionModel: String { String(localized: "home.engine.reactions.model", defaultValue: "Classifier Model", table: "Home", bundle: .localizedModule) }
    static var reactionPrompt: String { String(localized: "home.engine.reactions.prompt", defaultValue: "Instructions", table: "Home", bundle: .localizedModule) }
    /// The harness field's placeholder while neither this Chief nor cmux.json names one.
    static var reactionHarnessDefault: String { String(localized: "home.engine.reactions.harnessDefault", defaultValue: "Default (Claude route)", table: "Home", bundle: .localizedModule) }
    static var reactionPromptBuiltIn: String { String(localized: "home.engine.reactions.promptBuiltIn", defaultValue: "Built-in instructions", table: "Home", bundle: .localizedModule) }
    /// A picker's "Default" item naming what it runs: "Default (claude)", "Default (Opus 5.5)".
    static var defaultNamedFormat: String {
        String(localized: "home.engine.defaultNamed", defaultValue: "Default (%@)", table: "Home", bundle: .localizedModule)
    }
    // Computer (cmux issue 36047): where a Chief of this Mac does computer use.
    static var computerSection: String { String(localized: "home.engine.section.computer", defaultValue: "cmux Computer Use", table: "Home", bundle: .localizedModule) }
    static var computerRow: String { String(localized: "home.engine.computer", defaultValue: "Computer", table: "Home", bundle: .localizedModule) }
    static var computerThisMac: String { String(localized: "home.engine.computer.thisMac", defaultValue: "This Mac", table: "Home", bundle: .localizedModule) }
    static var computerNew: String { String(localized: "home.engine.computer.new", defaultValue: "New Cloud Computer…", table: "Home", bundle: .localizedModule) }
    static var computerMacNote: String {
        String(localized: "home.engine.computer.macNote", defaultValue: "The Chief clicks and types in this Mac's apps. Pick a Cloud computer to keep it off this Mac.",
               table: "Home", bundle: .localizedModule)
    }
    static var computerCloudNote: String {
        String(localized: "home.engine.computer.cloudNote", defaultValue: "The Chief clicks, types and browses on this Cloud computer, starting with its next turn.",
               table: "Home", bundle: .localizedModule)
    }
    static var computerShowDesktop: String {
        String(localized: "home.engine.computer.showDesktop", defaultValue: "Show Desktop", table: "Home", bundle: .localizedModule)
    }
    static var agentSection: String { String(localized: "home.engine.section.agent", defaultValue: "Agent", table: "Home", bundle: .localizedModule) }
    static var appearanceSection: String {
        String(localized: "home.engine.section.appearance", defaultValue: "Appearance", table: "Home", bundle: .localizedModule)
    }
    static var diagnostics: String { String(localized: "home.engine.section.diagnostics", defaultValue: "Diagnostics", table: "Home", bundle: .localizedModule) }
    /// Under the name, for a Chief whose brain runs here.
    public static var runsHere: String { String(localized: "home.engine.runsHere", defaultValue: "Runs on this Mac", table: "Home", bundle: .localizedModule) }
    /// The Hosted Chief's place line.
    public static var runsInCloud: String {
        String(localized: "home.engine.runsInCloud", defaultValue: "Runs in the cloud", table: "Home", bundle: .localizedModule)
    }
    /// A paired server's place line, by its name.
    public static var runsOnFormat: String {
        String(localized: "home.engine.runsOn", defaultValue: "Runs on %@", table: "Home", bundle: .localizedModule)
    }
    /// The card's link to the same Chief on its other host.
    static var switchHostFormat: String {
        String(localized: "home.engine.switchHost", defaultValue: "Switch to %@", table: "Home", bundle: .localizedModule)
    }
    /// The avatar's tooltip and VoiceOver label: a click opens its menu.
    static var changePicture: String {
        String(localized: "home.engine.changePicture", defaultValue: "Change Picture", table: "Home", bundle: .localizedModule)
    }
    static var name: String { String(localized: "home.engine.name", defaultValue: "Name", table: "Home", bundle: .localizedModule) }
    static var choosePicture: String {
        String(localized: "home.engine.choosePicture", defaultValue: "Choose Picture…", table: "Home", bundle: .localizedModule)
    }
    static var useDefaultPicture: String {
        String(localized: "home.engine.useDefaultPicture", defaultValue: "Use Default Picture", table: "Home", bundle: .localizedModule)
    }
    /// "%@ did not pass its check…" (the harness's name).
    static var harnessCheckFailedFormat: String {
        String(localized: "home.engine.harnessCheckFailed", defaultValue: "%@ did not pass its check, so the Chief stays on what it runs now.",
               table: "Home", bundle: .localizedModule)
    }
    /// "Checking %@…" (the harness's name) while its backend check runs.
    static var harnessCheckingFormat: String {
        String(localized: "home.engine.harnessChecking", defaultValue: "Checking %@…", table: "Home", bundle: .localizedModule)
    }
    static var renameRefused: String {
        // retry-prompt-ok: a rename is the person's edit, refused by the brain
        String(localized: "home.engine.renameRefused", defaultValue: "The Chief's name could not be changed. Try again in a moment.",
               table: "Home", bundle: .localizedModule)
    }
    /// Why a rename did not take (``HomeChiefRenameFailure``), shown under the name.
    static func renameFailed(_ failure: HomeChiefRenameFailure) -> String {
        switch failure {
        case .noConnection: renameRefused
        case .signedOut:
            String(localized: "home.engine.renameSignedOut",
                   defaultValue: "Sign in to cmux to rename this Chief. It runs in the cloud on your account.", table: "Home", bundle: .localizedModule)
        case .changedElsewhere:
            String(localized: "home.engine.renameChangedElsewhere",
                   defaultValue: "This Chief was changed on another device at the same time. Enter the new name again.", table: "Home", bundle: .localizedModule)
        case .invalidName:
            String(localized: "home.engine.renameInvalidName", defaultValue: "That name can’t be used. Use 1 to 100 characters.",
                   table: "Home", bundle: .localizedModule)
        case .notFound:
            String(localized: "home.engine.renameNotFound", defaultValue: "This Chief is no longer on your account, so its name can’t be changed.",
                   table: "Home", bundle: .localizedModule)
        case .refused(let reason):
            String(format: String(localized: "home.engine.renameRefusedReason", defaultValue: "The Chief’s name could not be changed (%@).",
                                  table: "Home", bundle: .localizedModule), reason)
        }
    }
    /// The settings card's Primary Chief checkbox: texts to the cmux line go to this Chief.
    static var primaryRow: String { String(localized: "home.engine.primary", defaultValue: "Primary Chief", table: "Home", bundle: .localizedModule) }
    static var primaryNote: String {
        String(localized: "home.engine.primaryNote", defaultValue: "Your texts to the cmux number go to your primary Chief.", table: "Home", bundle: .localizedModule)
    }
    /// `home.setPrimaryChief` named no Chief of the account.
    public static var primaryUnknown: String {
        String(localized: "home.engine.primaryUnknown", defaultValue: "No Chief on your account has that name or id.", table: "Home", bundle: .localizedModule)
    }
    /// Why a Chief could not be made primary (``HomeChiefRenameFailure``).
    public static func primaryFailed(_ failure: HomeChiefRenameFailure) -> String {
        switch failure {
        case .signedOut:
            String(localized: "home.engine.primarySignedOut", defaultValue: "Sign in to cmux to choose your primary Chief.", table: "Home", bundle: .localizedModule)
        case .notFound: primaryUnknown
        default:
            // retry-prompt-ok: making a Chief primary is a side-effecting change the person chose
            String(localized: "home.engine.primaryRefused", defaultValue: "This Chief couldn’t be made primary. Try again.", table: "Home", bundle: .localizedModule)
        }
    }
    /// Move and Scale's title: the editor a chosen or dropped Chief picture opens in.
    static var cropTitle: String {
        String(localized: "home.engine.cropTitle", defaultValue: "Move and Scale", table: "Home", bundle: .localizedModule)
    }
    static var cropHint: String {
        String(localized: "home.engine.cropHint", defaultValue: "Drag to move the picture. Scroll or pinch to zoom.", table: "Home", bundle: .localizedModule)
    }
    static var cropZoom: String {
        String(localized: "home.engine.cropZoom", defaultValue: "Zoom", table: "Home", bundle: .localizedModule)
    }
    static var cropSave: String {
        String(localized: "home.engine.cropSave", defaultValue: "Save", table: "Home", bundle: .localizedModule)
    }
    static var pictureUnreadable: String {
        String(localized: "home.engine.pictureUnreadable", defaultValue: "That picture could not be used. Choose a PNG, JPEG, HEIC, WebP, or a GIF up to 1 MB.",
               table: "Home", bundle: .localizedModule)
    }
    static var answeredBy: String { String(localized: "home.engine.answeredBy", defaultValue: "Recent replies, answered by:", table: "Home", bundle: .localizedModule) }

    /// "“Both subagents are done…” claude-sr, claude-opus-5-5", or the engine
    /// alone for a turn whose reply the trace kept no text of (no empty quotes).
    static func reply(_ turn: HomeEngineTurn) -> String {
        let engine = [turn.harness, turn.model].compactMap { $0 }.joined(separator: ", ")
        let text = turn.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? engine : "\u{201C}\(text)\u{201D} \(engine)"
    }

    static var noTurn: String { String(localized: "home.engine.noTurn", defaultValue: "No turn yet", table: "Home", bundle: .localizedModule) }

    /// "Last turn: claude-sr, claude-opus-5-5, 7.8 s, 1 tool call, 50% cached, $0.144".
    static func lastTurn(_ turn: HomeEngineTurn) -> String {
        let engine = [turn.harness, turn.model].compactMap { $0 }.joined(separator: ", ")
        // Numbers in the reader's own format (decimal mark, percent sign, currency).
        let hit = turn.hitRate.map { $0.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .toNearestOrAwayFromZero)) } ?? "-"
        let cost = turn.cost.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(3))) } ?? "-"
        let (tools, errors) = (turn.tools, turn.toolErrors)
        let calls = String(localized: "home.engine.toolCalls", defaultValue: "\(tools) tool calls", table: "Home", bundle: .localizedModule)
        let failed = String(localized: "home.engine.toolFailures", defaultValue: "\(errors) failed", table: "Home", bundle: .localizedModule)
        let format = String(localized: "home.engine.lastTurn",
                            defaultValue: "Last turn: %1$@, %2$@ s, %3$@ (%4$@), %5$@ cached, %6$@",
                            table: "Home", bundle: .localizedModule)
        return String(format: format, engine, turn.seconds.formatted(.number.precision(.fractionLength(1))), calls, failed, hit, cost)
    }
}
