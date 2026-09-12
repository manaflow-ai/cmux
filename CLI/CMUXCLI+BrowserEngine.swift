import Foundation
import CmuxBrowser

extension CMUXCLI {
    /// Removes the browser-pane engine option from CLI arguments and validates
    /// its value before any URL or selector parsing runs.
    func parseBrowserEngineOption(_ args: [String]) throws -> (engine: String?, remaining: [String]) {
        var remaining: [String] = []
        var engine: String?
        var index = 0
        var pastTerminator = false

        while index < args.count {
            let argument = args[index]
            if pastTerminator || argument == "--" {
                pastTerminator = true
                remaining.append(argument)
                index += 1
                continue
            }

            if argument == "--engine" {
                guard index + 1 < args.count else {
                    throw CLIError(message: String(
                        localized: "browser.engine.error.invalid",
                        defaultValue: "--engine requires webkit or chromium"
                    ))
                }
                engine = try validatedBrowserEngine(args[index + 1])
                index += 2
                continue
            }

            if argument.hasPrefix("--engine=") {
                engine = try validatedBrowserEngine(String(argument.dropFirst("--engine=".count)))
                index += 1
                continue
            }

            remaining.append(argument)
            index += 1
        }

        return (engine, remaining)
    }

    private func validatedBrowserEngine(_ rawValue: String) throws -> String {
        guard let engine = BrowserEngineKind.parse(rawValue) else {
            throw CLIError(message: String(
                localized: "browser.engine.error.invalid",
                defaultValue: "--engine requires webkit or chromium"
            ))
        }
        return engine.rawValue
    }

    func browserEngineRequiresBrowserType(
        _ engine: String?,
        type: String?
    ) throws {
        guard engine != nil else { return }
        guard BrowserEngineKind.isBrowserPanelType(type) else {
            throw CLIError(message: BrowserEngineKind.browserOnlyOptionMessage)
        }
    }
}
