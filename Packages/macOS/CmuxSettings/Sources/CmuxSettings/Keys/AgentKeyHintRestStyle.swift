import Foundation

/// The calm marker shown under clickable agent output while it is at rest.
public enum AgentKeyHintRestStyle: String, CaseIterable, Sendable, SettingCodable {
    case dotted
    case underline
    case none
}
