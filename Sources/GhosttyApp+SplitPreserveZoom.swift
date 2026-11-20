import Foundation
import GhosttyKit

/// Ghostty's `split-preserve-zoom` flags. The C config API returns the packed
/// struct as its bit representation, the same layout Ghostty's macOS app reads.
struct GhosttySplitPreserveZoom: OptionSet, Sendable {
    let rawValue: CUnsignedInt

    /// Keep a zoomed split zoomed when navigation moves focus to another split.
    static let navigation = GhosttySplitPreserveZoom(rawValue: 1 << 0)

    init(rawValue: CUnsignedInt) {
        self.rawValue = rawValue
    }

    init(config: ghostty_config_t?) {
        var value: CUnsignedInt = 0
        let key = "split-preserve-zoom"
        guard let config,
              ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            self = []
            return
        }
        self.init(rawValue: value)
    }
}

extension GhosttyApp {
    /// The current `split-preserve-zoom` setting, read live so a config
    /// reload applies to the next navigation.
    var splitPreserveZoom: GhosttySplitPreserveZoom {
        GhosttySplitPreserveZoom(config: config)
    }
}
