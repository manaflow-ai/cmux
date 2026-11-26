extension DiagnosticEventPresentation {
    /// The stable machine name of an event code.
    public func name(_ code: DiagnosticEventCode) -> String {
        String(describing: code)
    }

    /// The stable machine name of a failure kind.
    public func name(_ kind: DiagnosticFailureKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a task-model retry stop reason.
    public func name(_ reason: DiagnosticTaskModelRetryStopReason) -> String {
        String(describing: reason)
    }

    /// The stable machine name of a transport kind.
    public func name(_ kind: DiagnosticTransportKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a path kind.
    public func name(_ kind: DiagnosticPathKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a session lifecycle kind.
    public func name(_ kind: DiagnosticSessionLifecycleKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of an app lifecycle phase.
    public func name(_ phase: DiagnosticAppLifecyclePhase) -> String {
        String(describing: phase)
    }

    /// The stable machine name of an app-wide iOS feature event.
    public func name(_ kind: DiagnosticAppEventKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a terminal toolbar action.
    public func name(_ action: DiagnosticTerminalToolbarAction) -> String {
        String(describing: action)
    }

    /// The stable machine name of a terminal zoom action.
    public func name(_ action: DiagnosticTerminalZoomAction) -> String {
        String(describing: action)
    }

    /// The stable machine name of a primary navigation destination.
    public func name(_ tab: DiagnosticPrimaryTab) -> String {
        String(describing: tab)
    }

    /// The stable machine name of a primary search owner.
    public func name(_ scope: DiagnosticSearchScope) -> String {
        String(describing: scope)
    }

    /// The stable machine name of a terminal toolbar configuration mutation.
    public func name(_ action: DiagnosticToolbarConfigurationAction) -> String {
        String(describing: action)
    }

    /// The stable machine name of a feedback delivery route.
    public func name(_ route: DiagnosticFeedbackRoute) -> String {
        String(describing: route)
    }

    /// The stable machine name of a toast style.
    public func name(_ style: DiagnosticToastStyle) -> String {
        String(describing: style)
    }

    /// The stable machine name of a toast dismissal reason.
    public func name(_ reason: DiagnosticToastDismissReason) -> String {
        String(describing: reason)
    }

    /// The stable machine name of a runtime role.
    public func name(_ role: DiagnosticRuntimeRole) -> String {
        String(describing: role)
    }

    /// The stable machine name of a Simulator stream lifecycle edge.
    public func name(_ kind: DiagnosticSimulatorStreamLifecycle) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator frame lifecycle edge.
    public func name(_ kind: DiagnosticSimulatorFrameLifecycle) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator input lifecycle edge.
    public func name(_ kind: DiagnosticSimulatorInputLifecycle) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator input kind.
    public func name(_ kind: DiagnosticSimulatorInputKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator hardware button kind.
    public func name(_ kind: DiagnosticSimulatorHardwareButtonKind) -> String {
        String(describing: kind)
    }

    /// The stable machine name of a Simulator pointer phase.
    public func name(_ phase: DiagnosticSimulatorPointerPhase) -> String {
        String(describing: phase)
    }

    /// The stable machine name of a Simulator ownership state.
    public func name(_ state: DiagnosticSimulatorOwnershipState) -> String {
        String(describing: state)
    }

    /// The stable machine name of a Simulator coordinate mapping state.
    public func name(_ state: DiagnosticSimulatorCoordinateState) -> String {
        String(describing: state)
    }

}
