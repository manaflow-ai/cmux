import CmuxNextInputCore
import Foundation

/// The words of the input rows (ActionLatencyHUD.xcstrings): an input's kind, its target and its
/// stages, each from a stable key, so renaming an enum case never changes what the panel says.
extension ActionLatencyHUD {
    static func label(_ kind: InputEventKind) -> String {
        switch kind {
        case .keyPress:
            String(localized: "actionLatencyHUD.kind.keyPress", defaultValue: "key down", table: "ActionLatencyHUD",
                   bundle: .module)
        case .keyRelease:
            String(localized: "actionLatencyHUD.kind.keyRelease", defaultValue: "key up", table: "ActionLatencyHUD",
                   bundle: .module)
        case .flags:
            String(localized: "actionLatencyHUD.kind.flags", defaultValue: "modifier", table: "ActionLatencyHUD",
                   bundle: .module)
        case .mousePress:
            String(localized: "actionLatencyHUD.kind.mousePress", defaultValue: "mouse down", table: "ActionLatencyHUD",
                   bundle: .module)
        case .mouseRelease:
            String(localized: "actionLatencyHUD.kind.mouseRelease", defaultValue: "mouse up", table: "ActionLatencyHUD",
                   bundle: .module)
        case .pointerMove:
            String(localized: "actionLatencyHUD.kind.pointerMove", defaultValue: "pointer move", table: "ActionLatencyHUD",
                   bundle: .module)
        case .drag:
            String(localized: "actionLatencyHUD.kind.drag", defaultValue: "drag", table: "ActionLatencyHUD",
                   bundle: .module)
        case .scrollBegin:
            String(localized: "actionLatencyHUD.kind.scrollBegin", defaultValue: "scroll begin", table: "ActionLatencyHUD",
                   bundle: .module)
        case .scrollFirstUpdate:
            String(localized: "actionLatencyHUD.kind.scrollFirstUpdate", defaultValue: "first scroll", table: "ActionLatencyHUD",
                   bundle: .module)
        case .scrollUpdate:
            String(localized: "actionLatencyHUD.kind.scrollUpdate", defaultValue: "scroll", table: "ActionLatencyHUD",
                   bundle: .module)
        case .scrollMomentum:
            String(localized: "actionLatencyHUD.kind.scrollMomentum", defaultValue: "momentum", table: "ActionLatencyHUD",
                   bundle: .module)
        case .scrollEnd:
            String(localized: "actionLatencyHUD.kind.scrollEnd", defaultValue: "scroll end", table: "ActionLatencyHUD",
                   bundle: .module)
        case .magnify:
            String(localized: "actionLatencyHUD.kind.magnify", defaultValue: "magnify", table: "ActionLatencyHUD",
                   bundle: .module)
        }
    }

    static func label(_ target: InputTarget) -> String {
        switch target {
        case .terminal:
            String(localized: "actionLatencyHUD.target.terminal", defaultValue: "terminal", table: "ActionLatencyHUD",
                   bundle: .module)
        case .textView:
            String(localized: "actionLatencyHUD.target.textView", defaultValue: "text view", table: "ActionLatencyHUD",
                   bundle: .module)
        case .chromiumPage:
            String(localized: "actionLatencyHUD.target.chromiumPage", defaultValue: "Chromium page", table: "ActionLatencyHUD",
                   bundle: .module)
        case .webkitPage:
            String(localized: "actionLatencyHUD.target.webkitPage", defaultValue: "WebKit page", table: "ActionLatencyHUD",
                   bundle: .module)
        case .agentPane:
            String(localized: "actionLatencyHUD.target.agentPane", defaultValue: "agent pane", table: "ActionLatencyHUD",
                   bundle: .module)
        case .layout:
            String(localized: "actionLatencyHUD.target.layout", defaultValue: "layout", table: "ActionLatencyHUD",
                   bundle: .module)
        case .sidebar:
            String(localized: "actionLatencyHUD.target.sidebar", defaultValue: "sidebar", table: "ActionLatencyHUD",
                   bundle: .module)
        case .palette:
            String(localized: "actionLatencyHUD.target.palette", defaultValue: "palette", table: "ActionLatencyHUD",
                   bundle: .module)
        case .other:
            String(localized: "actionLatencyHUD.target.other", defaultValue: "other", table: "ActionLatencyHUD",
                   bundle: .module)
        }
    }

    static func label(_ stage: InputStage) -> String {
        switch stage {
        case .generated:
            String(localized: "actionLatencyHUD.stage.generated", defaultValue: "OS event", table: "ActionLatencyHUD",
                   bundle: .module)
        case .lastGenerated:
            String(localized: "actionLatencyHUD.stage.lastGenerated", defaultValue: "last OS event", table: "ActionLatencyHUD",
                   bundle: .module)
        case .arrivedMain:
            String(localized: "actionLatencyHUD.stage.arrivedMain", defaultValue: "main thread", table: "ActionLatencyHUD",
                   bundle: .module)
        case .dispatchStart:
            String(localized: "actionLatencyHUD.stage.dispatchStart", defaultValue: "dispatch start", table: "ActionLatencyHUD",
                   bundle: .module)
        case .textInputStart:
            String(localized: "actionLatencyHUD.stage.textInputStart", defaultValue: "text input start", table: "ActionLatencyHUD",
                   bundle: .module)
        case .textInputEnd:
            String(localized: "actionLatencyHUD.stage.textInputEnd", defaultValue: "text input end", table: "ActionLatencyHUD",
                   bundle: .module)
        case .dispatchEnd:
            String(localized: "actionLatencyHUD.stage.dispatchEnd", defaultValue: "dispatch end", table: "ActionLatencyHUD",
                   bundle: .module)
        case .mainCommit:
            String(localized: "actionLatencyHUD.stage.mainCommit", defaultValue: "commit", table: "ActionLatencyHUD",
                   bundle: .module)
        case .contentSubmitted:
            String(localized: "actionLatencyHUD.stage.contentSubmitted", defaultValue: "content submitted", table: "ActionLatencyHUD",
                   bundle: .module)
        case .daemonReceived:
            String(localized: "actionLatencyHUD.stage.daemonReceived", defaultValue: "daemon received", table: "ActionLatencyHUD",
                   bundle: .module)
        case .ptyWritten:
            String(localized: "actionLatencyHUD.stage.ptyWritten", defaultValue: "PTY written", table: "ActionLatencyHUD",
                   bundle: .module)
        case .echoRead:
            String(localized: "actionLatencyHUD.stage.echoRead", defaultValue: "echo read", table: "ActionLatencyHUD",
                   bundle: .module)
        case .echoSent:
            String(localized: "actionLatencyHUD.stage.echoSent", defaultValue: "echo sent", table: "ActionLatencyHUD",
                   bundle: .module)
        case .presented:
            String(localized: "actionLatencyHUD.stage.presented", defaultValue: "presented", table: "ActionLatencyHUD",
                   bundle: .module)
        case .echoParsed:
            String(localized: "actionLatencyHUD.stage.echoParsed", defaultValue: "echo parsed", table: "ActionLatencyHUD",
                   bundle: .module)
        }
    }
}
