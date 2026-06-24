public import Foundation

/// The icon shown for an index section: an agent glyph or a folder glyph.
public enum SectionIcon: Equatable, Sendable {
    case agent(SessionAgent)
    case folder
}
