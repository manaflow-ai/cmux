#if DEBUG
import AppKit

/// DEBUG ONLY (Environment Secrets Playground): the four row types of the proposed Environment page.
/// The playground's labels are DEV-only English, as the other playgrounds' are.
enum EnvSecretsKind: Int, CaseIterable, Identifiable {
    /// Not secret (`NODE_ENV`, `REGION`): plain env, readable later.
    case variable
    /// Kept out of the machine: the agent gets a placeholder, the value is added on the way out to its hosts.
    case apiSecret
    /// Given to the setup script, removed before the agent starts.
    case setupSecret
    /// The escape hatch: plain env in the machine, with a warning.
    case envSecret

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .variable: "Variable"
        case .apiSecret: "Secret for an API"
        case .setupSecret: "Secret for setup only"
        case .envSecret: "Secret in the environment"
        }
    }

    var short: String {
        switch self {
        case .variable: "Variable"
        case .apiSecret: "API secret"
        case .setupSecret: "Setup only"
        case .envSecret: "In environment"
        }
    }

    var symbol: String {
        switch self {
        case .variable: "textformat"
        case .apiSecret: "lock.shield"
        case .setupSecret: "hammer"
        case .envSecret: "exclamationmark.triangle"
        }
    }

    var tint: NSColor {
        switch self {
        case .variable: NSColor.secondaryLabelColor
        case .apiSecret: NSColor.systemTeal
        case .setupSecret: NSColor.systemIndigo
        case .envSecret: NSColor.systemOrange
        }
    }

    /// What the type promises, in one sentence.
    var promise: String {
        switch self {
        case .variable: "A plain value. Anyone who uses this environment can read it."
        case .apiSecret: "The agent sees only a placeholder. cmux adds the value on the way out, only to the hosts below."
        case .setupSecret: "Given to the setup script, then removed before the agent starts."
        case .envSecret: "The agent and any code it runs can read and print this value."
        }
    }
}
#endif
