/// Modifier bits of `cmux.rb/1` input events.
public struct RbModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = RbModifiers(rawValue: 1)
    public static let control = RbModifiers(rawValue: 1 << 1)
    public static let option = RbModifiers(rawValue: 1 << 2)
    public static let command = RbModifiers(rawValue: 1 << 3)
    public static let capsLock = RbModifiers(rawValue: 1 << 4)
    public static let function = RbModifiers(rawValue: 1 << 5)
}
