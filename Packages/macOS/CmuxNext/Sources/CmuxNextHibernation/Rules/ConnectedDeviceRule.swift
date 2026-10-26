// p07-memory.md section 3.C: one file per discard rule, listed once in `DiscardRule.registered`.

nonisolated extension DiscardRule {
    /// An open USB, HID or serial device, or a connected Bluetooth GATT server (Chrome's
    /// `kConnectedToUSB` and `kConnectedToBluetooth`; lead rule).
    package static let connectedDevice = DiscardRule(.connectedDevice, result: .protected, for: DiscardRule.leadRule) { candidate, _ in
        candidate.hasConnectedDevice
    }
}
