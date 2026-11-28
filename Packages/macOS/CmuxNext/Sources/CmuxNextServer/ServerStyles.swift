public import CmuxNextDesign

/// Menubar panel prototypes (`server.panel.style`, server.md section 14).
public nonisolated enum ServerPanelStyle: String, Sendable, CaseIterable, TunableChoice {
    /// Status line, on/off switch, four rows.
    case compact
    /// A card per role with counts, and the pairing card.
    case dashboard
    /// Grouped list (apps, health, devices) with inline actions.
    case list

    public var tunableTitle: String {
        switch self {
        case .compact: "Compact (status + four rows)"
        case .dashboard: "Dashboard (card per role)"
        case .list: "List (apps, health, devices)"
        }
    }
}

/// Server-side pairing prototypes (`server.pairing.style`).
public nonisolated enum ServerPairingStyle: String, Sendable, CaseIterable, TunableChoice {
    /// Large code, small QR, the four words.
    case code
    /// Large QR, code below.
    case qr
    /// The four words first, the code in a field (for reading aloud).
    case words

    public var tunableTitle: String {
        switch self {
        case .code: "Code first"
        case .qr: "QR first"
        case .words: "Words first"
        }
    }
}

/// Health view prototypes (`server.health.style`).
public nonisolated enum ServerHealthStyle: String, Sendable, CaseIterable, TunableChoice {
    /// Every check with its state and Fix.
    case checklist
    /// One status line, only the open issues.
    case summary
    /// Alerts over time with resolve markers.
    case timeline

    public var tunableTitle: String {
        switch self {
        case .checklist: "Checklist (every check)"
        case .summary: "Summary (open issues only)"
        case .timeline: "Timeline (alerts over time)"
        }
    }
}
