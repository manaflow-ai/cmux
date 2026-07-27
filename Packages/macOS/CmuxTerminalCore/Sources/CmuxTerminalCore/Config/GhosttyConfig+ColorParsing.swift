import AppKit
import Foundation
import GhosttyKit

extension GhosttyConfig {
    func parseGhosttyColor(_ value: String) -> NSColor? {
        if let color = NSColor(hex: value) {
            return color
        }

        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }

        let directive = "foreground = \(value)"
        directive.withCString { contents in
            "/__cmux_color_parser__/config".withCString { path in
                ghostty_config_load_string(
                    config,
                    contents,
                    UInt(directive.lengthOfBytes(using: .utf8)),
                    path
                )
            }
        }

        guard ghostty_config_diagnostics_count(config) == 0 else { return nil }

        var color = ghostty_config_color_s()
        let key = "foreground"
        guard ghostty_config_get(
            config,
            &color,
            key,
            UInt(key.lengthOfBytes(using: .utf8))
        ) else { return nil }

        return NSColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }
}
