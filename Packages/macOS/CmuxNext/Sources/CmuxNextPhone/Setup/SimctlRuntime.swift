/// One installed iOS simulator runtime and the iPhone models it can run
/// (from `simctl list runtimes -j`).
public struct SimctlRuntime: Sendable, Hashable {
    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-0`.
    public var identifier: String
    /// "iOS 18.0".
    public var name: String
    /// [18, 0], for picking the newest.
    public var version: [Int]
    /// The iPhone device types this runtime supports, in simctl's order (oldest first).
    public var iPhoneTypes: [SimctlDeviceType]

    public init(identifier: String, name: String, version: [Int], iPhoneTypes: [SimctlDeviceType]) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.iPhoneTypes = iPhoneTypes
    }

    /// The iPhone a new user gets: the newest plain model ("iPhone 17", not
    /// "Pro Max" or "e"), else the newest iPhone of any kind.
    public var suggestedIPhone: SimctlDeviceType? {
        let plain = iPhoneTypes.filter { type in
            let words = type.name.split(separator: " ")
            return words.count == 2 && words[0] == "iPhone" && Int(words[1]) != nil
        }
        return plain.max { (Int($0.name.split(separator: " ")[1]) ?? 0) < (Int($1.name.split(separator: " ")[1]) ?? 0) } ?? iPhoneTypes.last
    }
}

/// A simulator hardware model (`com.apple.CoreSimulator.SimDeviceType.iPhone-17`, "iPhone 17").
public struct SimctlDeviceType: Sendable, Hashable {
    public var identifier: String
    public var name: String

    public init(identifier: String, name: String) {
        self.identifier = identifier
        self.name = name
    }
}
