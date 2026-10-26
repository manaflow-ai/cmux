import Foundation

extension SidebarMachine {
    /// A remote machine's room as its remote group's header shows it: a second line under the name
    /// ("31 GB free · CPU 12/32", a problem first when there is one), the whole reading on hover,
    /// and what VoiceOver reads after the name. Set by the app from the machine's acpmux peer
    /// reading; nil for a machine without one, which keeps its header one line.
    public nonisolated struct Room: Hashable, Sendable {
        public var line: String
        public var toolTip: String
        public var spoken: String

        public init(line: String, toolTip: String, spoken: String) {
            (self.line, self.toolTip, self.spoken) = (line, toolTip, spoken)
        }
    }
}
