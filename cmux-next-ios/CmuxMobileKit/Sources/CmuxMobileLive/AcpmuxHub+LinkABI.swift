#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation

/// The acpmux wire ABI range on the phone's link to its Mac (hq RFD 0224, phase 2). The rules are
/// Rust (`cmux-mobile-link-ffi` `link_abi.rs`); this is the glue: the phone names its range in
/// `initialize`, reads the Mac's back, and turns a range the two do not share, either side's
/// verdict, into one link error naming what to update.
extension AcpmuxHub {
    /// The link error code for a phone and a Mac that share no ABI revision. Not transient: the
    /// link redialing does not fix it, an update does.
    nonisolated static let versionIncompatible = "version.incompatible"

    /// `abi` and `abiMin` for the phone's `initialize` `_meta.acpmux`; empty where the Rust link
    /// is not built in, which the Mac reads as a client from before the fields (always served).
    nonisolated static var initializeABIMeta: [String: JSONValue] {
        #if canImport(CmuxMobileLinkFFI)
        let range = phoneAbiRange()
        return ["abi": .number(Double(range.max)), "abiMin": .number(Double(range.min))]
        #else
        return [:]
        #endif
    }

    /// The error for a Mac whose `initialize` result names a range this app does not read.
    nonisolated static func abiIncompatible(initialized: JSONValue) -> LinkError? {
        #if canImport(CmuxMobileLinkFFI)
        guard let data = try? JSONEncoder().encode(initialized),
              let json = String(data: data, encoding: .utf8),
              let verdict = phoneAbiCheck(initializeResultJson: json) else { return nil }
        return LinkError(code: versionIncompatible, message: verdict.reason)
        #else
        return nil
        #endif
    }

    /// The error for the Mac refusing the phone's `initialize` with acpmux's `version.incompatible`.
    nonisolated static func abiIncompatible(refusal error: any Error) -> LinkError? {
        #if canImport(CmuxMobileLinkFFI)
        guard let error = error as? AcpmuxConnection.RPCError, error.errorKind == versionIncompatible else { return nil }
        let details: JSONValue = .object([
            "errorKind": .string(versionIncompatible),
            "details": .object(["update": error.update.map(JSONValue.string) ?? .null]),
        ])
        guard let data = try? JSONEncoder().encode(details),
              let json = String(data: data, encoding: .utf8),
              let verdict = phoneAbiRefusal(errorDataJson: json) else { return nil }
        return LinkError(code: versionIncompatible, message: verdict.reason)
        #else
        return nil
        #endif
    }
}
