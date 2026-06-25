/// Focus-policy predicates derived purely from a ``PanelFocusIntent``.
///
/// Each property answers a single yes/no question about how a panel activation
/// should treat focus, computed only from the intent with no panel or workspace
/// state. They drive the workspace's tab-activation focus convergence (whether
/// to move terminal surface first-responder, focus a browser web view,
/// auto-focus the browser omnibar, or restore the captured sub-control focus
/// after activation).
extension PanelFocusIntent {
    /// Whether activating a terminal panel for this intent should move the
    /// terminal surface first-responder.
    ///
    /// Find-field and text-box-input intents keep focus on their own control,
    /// so the surface focus is not moved for those.
    public var movesTerminalSurfaceFocus: Bool {
        switch self {
        case .terminal(.findField), .terminal(.textBoxInput):
            return false
        default:
            return true
        }
    }

    /// Whether activating a browser panel for this intent should focus the web
    /// view.
    ///
    /// Address-bar and find-field intents keep focus on those controls instead
    /// of the web view.
    public var focusesBrowserWebView: Bool {
        switch self {
        case .browser(.addressBar), .browser(.findField):
            return false
        default:
            return true
        }
    }

    /// Whether this intent permits auto-focusing the browser omnibar when a
    /// browser panel gains focus.
    ///
    /// Only a web-view intent or the whole-panel default allows the omnibar
    /// autofocus; explicit address-bar/find intents do not re-trigger it.
    public var allowsBrowserOmnibarAutofocus: Bool {
        switch self {
        case .browser(.webView), .panel:
            return true
        default:
            return false
        }
    }

    /// Whether the panel's captured sub-control focus should be restored after
    /// activation completes.
    ///
    /// Restoration applies to the control-specific browser/terminal intents
    /// (address bar, find field, text-box input); whole-panel and primary
    /// surface/web-view intents do not restore a sub-control.
    public var restoresAfterActivation: Bool {
        switch self {
        case .browser(.addressBar), .browser(.findField), .terminal(.findField), .terminal(.textBoxInput):
            return true
        case .panel, .browser(.webView), .terminal(.surface), .filePreview, .project:
            return false
        }
    }
}
