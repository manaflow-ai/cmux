import Foundation

extension CMUXCLI {
    /// Validates viewport CLI arguments and builds the `browser.viewport.set` parameters.
    static func browserViewportSetParams(
        _ arguments: [String],
        surfaceID: String
    ) throws -> [String: Any] {
        if arguments.first?.lowercased() == "reset" {
            guard arguments.count == 1 else {
                throw CLIError(
                    message: String(
                        localized: "cli.browser.error.viewportResetAdditionalArguments",
                        defaultValue: "browser viewport reset does not accept additional arguments"
                    )
                )
            }
            return ["surface_id": surfaceID, "reset": true]
        }

        guard arguments.count == 2,
              let width = Int(arguments[0]),
              let height = Int(arguments[1]) else {
            throw CLIError(
                message: String(
                    localized: "cli.browser.error.viewportRequiresSizeOrReset",
                    defaultValue: "browser viewport requires: <width> <height> | reset"
                )
            )
        }
        return ["surface_id": surfaceID, "width": width, "height": height]
    }

    /// Localized help text for setting or resetting a browser viewport.
    static var browserViewportHelp: String {
        let usage = String(
            localized: "cli.browser.help.viewportUsage",
            defaultValue: "viewport <width> <height> | reset"
        )
        let emulationDescription = String(
            localized: "cli.browser.help.viewportEmulationDescription",
            defaultValue: "Emulate an exact 1...4096 CSS-pixel viewport inside the pane without resizing it"
        )
        let presentationDescription = String(
            localized: "cli.browser.help.viewportPresentationDescription",
            defaultValue: "The page is aspect-fitted in the existing pane; reset restores native pane sizing"
        )
        let renderLimitDescription = String(
            localized: "cli.browser.help.viewportRenderLimitDescription",
            defaultValue: "Oversized viewport and page-zoom combinations return structured render-limit details"
        )
        return [
            usage,
            "  \(emulationDescription)",
            "  \(presentationDescription)",
            "  \(renderLimitDescription)",
        ]
            .joined(separator: "\n              ")
    }
}
