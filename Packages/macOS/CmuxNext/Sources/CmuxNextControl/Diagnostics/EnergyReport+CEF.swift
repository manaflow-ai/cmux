import CmuxNextSettings

extension EnergyReport {
    /// Chromium's side of Energy Saver.
    public struct CEF: Sendable, Equatable {
        public enum Saver: String, Sendable {
            /// The fork took the app's last saver state (`cmux_cef_set_energy_saver`).
            case applied
            /// Chromium has not taken it: not started, or a fork below the API (in process or in the Chromium Host,
            /// whose hello says whether its fork has it).
            case unsupported

            /// `applied` only when the engine says the fork took the last state; nil is no Chromium built yet.
            public init(applied: Bool?) { self = applied == true ? .applied : .unsupported }
        }

        public var saver: Saver
        /// Delayed pump passes CEF re-asked for under 2 ms during the pass; nil while the pump does not
        /// count them.
        public var earlyPasses: Int?

        public init(saver: Saver, earlyPasses: Int?) {
            self.saver = saver
            self.earlyPasses = earlyPasses
        }

        var json: JSONValue {
            [
                "energySaver": .string(saver.rawValue),
                "earlyPasses": earlyPasses.map { JSONValue($0) } ?? .null,
            ]
        }
    }
}
