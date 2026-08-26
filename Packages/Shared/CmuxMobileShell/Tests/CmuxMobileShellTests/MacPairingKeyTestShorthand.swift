@testable import CmuxMobileShell

extension String {
    /// Test shorthand: parse a literal device id or composite pairing id into
    /// the typed owner key, mirroring the production string contract.
    var pairingKey: MacPairingKey { MacPairingKey(pairingID: self) }
}
