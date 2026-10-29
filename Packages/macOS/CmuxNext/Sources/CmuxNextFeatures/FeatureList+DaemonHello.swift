extension FeatureList {
    /// One daemon feature's value as the app resolved it, for the daemon's `client-hello`.
    public struct DaemonValue: Sendable, Equatable {
        public let name: String
        public let isEnabled: Bool

        public init(name: String, isEnabled: Bool) {
            self.name = name
            self.isEnabled = isEnabled
        }
    }

    /// The values of the daemons' features (process `daemon` or `both`) in registry order: what the app's
    /// `client-hello` sends, because the daemon outlives the app. The daemon turns off a
    /// verified app's `daemon` kill switch at once and reports every other difference as pending, as Chromium's
    /// child processes keep the feature state they started with (`FeatureList::InitFromSharedMemory`).
    public var daemonValues: [DaemonValue] {
        zip(registry.features, resolutions).compactMap { feature, resolution in
            feature.process == .daemon || feature.process == .both
                ? DaemonValue(name: feature.name, isEnabled: resolution.isEnabled) : nil
        }
    }

    /// ``daemonValuesHash(_:)`` of ``daemonValues``.
    public var daemonValuesHash: String { Self.daemonValuesHash(daemonValues) }

    /// FNV-1a 64 of `name=1\n` (or `=0\n`) for each value in order, as 16 lowercase hex digits: the daemon's
    /// `cmux_features::values_hash`, so equal values in the same order give the same hash and the daemon skips
    /// the comparison.
    public static func daemonValuesHash(_ values: [DaemonValue]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func add(_ bytes: some Sequence<UInt8>) {
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
        for value in values {
            add(value.name.utf8)
            add((value.isEnabled ? "=1\n" : "=0\n").utf8)
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
