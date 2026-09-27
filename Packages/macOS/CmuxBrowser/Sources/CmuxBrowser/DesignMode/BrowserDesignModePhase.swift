
/// Exclusive design-mode interaction: pick elements or draw capture regions.
public enum BrowserDesignModeInteractionMode: String, Equatable {
    case select
    case draw
}

/// The one in-flight freehand annotation transaction owned by Design Mode.
public enum BrowserDesignModeAnnotationPhase: Equatable {
    case idle
    case drawing(id: String)
    case inkOnly(BrowserDesignModeAnnotationCaptureRequest)
    case capturing(BrowserDesignModeAnnotationCaptureRequest)
    case captured(id: String, selector: String)

    public var permitsHandoff: Bool {
        switch self {
        case .idle, .captured: true
        case .drawing, .inkOnly, .capturing: false
        }
    }
}

public enum BrowserDesignModePhase: Equatable {
    case inactive
    case activating
    case active(annotation: BrowserDesignModeAnnotationPhase)
    case deactivating

    public var isEnabled: Bool {
        if case .active = self { return true }
        return false
    }

    public var isTransitioning: Bool {
        self == .activating || self == .deactivating
    }

    public var annotation: BrowserDesignModeAnnotationPhase? {
        guard case .active(let annotation) = self else { return nil }
        return annotation
    }

    public var commandValue: String {
        switch self {
        case .inactive: "inactive"
        case .activating: "activating"
        case .active: "active"
        case .deactivating: "deactivating"
        }
    }
}
