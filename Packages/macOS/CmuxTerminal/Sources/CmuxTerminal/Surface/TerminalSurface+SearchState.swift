public import Combine

extension TerminalSurface {
    /// The live find-in-terminal session state for one surface.
    public final class SearchState: ObservableObject {
        /// The current search needle.
        @Published public var needle: String
        /// The 1-based index of the selected match, if known.
        @Published public var selected: UInt?

        /// The total number of matches, if known.
        @Published public var total: UInt?

        /// Creates search state with an initial needle.
        public init(needle: String = "") {
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

}
