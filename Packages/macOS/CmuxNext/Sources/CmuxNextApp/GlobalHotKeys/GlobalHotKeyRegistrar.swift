/// Registers system-wide hot keys. `CarbonHotKeyRegistrar` is the real one;
/// tests substitute a recorder.
protocol GlobalHotKeyRegistrar: AnyObject {
    /// Called with the registration number of a pressed hot key.
    var onPress: ((UInt32) -> Void)? { get set }
    /// Registers `hotKey` under `number`. False when the system refuses,
    /// usually because another app already holds the same key.
    func register(_ hotKey: CarbonHotKey, number: UInt32) -> Bool
    func unregister(number: UInt32)
}
