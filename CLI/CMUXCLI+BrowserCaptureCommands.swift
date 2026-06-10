import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

// MARK: - Browser capture subcommands
extension CMUXCLI {
    /// Handles screenshot and screencast.
    /// Returns true when the subcommand was handled.
    func runBrowserCaptureSubcommands(_ ctx: BrowserCommandContext, subcommand: String) throws -> Bool {
        if subcommand == "screenshot" {
            let sid = try ctx.requireSurface()
            let (outPathOpt, _) = parseOption(ctx.subArgs, name: "--out")
            let localJSONOutput = hasFlag(ctx.subArgs, name: "--json")
            let outputAsJSON = ctx.effectiveJSONOutput || localJSONOutput
            var payload = try ctx.client.sendV2(method: "browser.screenshot", params: ["surface_id": sid])

            func fileURL(fromPath rawPath: String) -> URL {
                let resolvedPath = resolvePath(rawPath)
                return URL(fileURLWithPath: resolvedPath).standardizedFileURL
            }

            func writeScreenshot(_ data: Data, to destinationURL: URL) throws {
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: .atomic)
            }

            func hasText(_ value: String?) -> Bool {
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            var screenshotPath = payload["path"] as? String
            var screenshotURL = payload["url"] as? String

            func syncScreenshotLocationFields() {
                if !hasText(screenshotPath),
                   let rawURL = screenshotURL,
                   let fileURL = URL(string: rawURL),
                   fileURL.isFileURL,
                   !fileURL.path.isEmpty {
                    screenshotPath = fileURL.path
                }
                if !hasText(screenshotURL),
                   let screenshotPath,
                   hasText(screenshotPath) {
                    screenshotURL = URL(fileURLWithPath: screenshotPath).standardizedFileURL.absoluteString
                }
                if let screenshotPath, hasText(screenshotPath) {
                    payload["path"] = screenshotPath
                }
                if let screenshotURL, hasText(screenshotURL) {
                    payload["url"] = screenshotURL
                }
            }

            func persistPayloadScreenshot(to destinationURL: URL, allowFailure: Bool) throws -> Bool {
                if let sourcePath = screenshotPath, hasText(sourcePath) {
                    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
                    do {
                        if sourceURL.path != destinationURL.path {
                            try FileManager.default.createDirectory(
                                at: destinationURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try? FileManager.default.removeItem(at: destinationURL)
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        }
                        return true
                    } catch {
                        if payload["png_base64"] == nil {
                            if allowFailure {
                                return false
                            }
                            throw error
                        }
                    }
                }

                if let b64 = payload["png_base64"] as? String,
                   let data = Data(base64Encoded: b64) {
                    do {
                        try writeScreenshot(data, to: destinationURL)
                        return true
                    } catch {
                        if allowFailure {
                            return false
                        }
                        throw error
                    }
                }

                return false
            }

            if let outPathOpt {
                let outputURL = fileURL(fromPath: outPathOpt)
                guard try persistPayloadScreenshot(to: outputURL, allowFailure: false) else {
                    throw CLIError(message: "browser screenshot missing image data")
                }
                screenshotPath = outputURL.path
                screenshotURL = outputURL.absoluteString
                payload["path"] = screenshotPath
                payload["url"] = screenshotURL
            } else {
                syncScreenshotLocationFields()
                if !hasText(screenshotPath) && !hasText(screenshotURL) {
                    let outputDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cmux-browser-screenshots-cli", isDirectory: true)
                    if (try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)) != nil {
                        bestEffortPruneTemporaryFiles(in: outputDir)
                        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                        let safeSid = sanitizedFilenameComponent(sid)
                        let filename = "surface-\(safeSid)-\(timestampMs)-\(String(UUID().uuidString.prefix(8))).png"
                        let outputURL = outputDir.appendingPathComponent(filename, isDirectory: false)
                        if (try? persistPayloadScreenshot(to: outputURL, allowFailure: true)) == true {
                            screenshotPath = outputURL.path
                            screenshotURL = outputURL.absoluteString
                            payload["path"] = screenshotPath
                            payload["url"] = screenshotURL
                        }
                    }
                }
            }

            if outputAsJSON {
                let formattedPayload = formatIDs(payload, mode: ctx.effectiveIDFormat)
                if var outputPayload = formattedPayload as? [String: Any] {
                    if hasText(screenshotPath) || hasText(screenshotURL) {
                        outputPayload.removeValue(forKey: "png_base64")
                    }
                    print(jsonString(outputPayload))
                } else {
                    print(jsonString(formattedPayload))
                }
            } else if let outPathOpt {
                print("OK \(outPathOpt)")
            } else if let screenshotURL,
                      hasText(screenshotURL) {
                print("OK \(screenshotURL)")
            } else if let screenshotPath,
                      hasText(screenshotPath) {
                print("OK \(screenshotPath)")
            } else {
                print("OK")
            }
            return true
        }

        if subcommand == "screencast" {
            let sid = try ctx.requireSurface()
            guard let castVerb = ctx.subArgs.first?.lowercased() else {
                throw CLIError(message: "browser screencast requires start|stop")
            }
            let method: String
            switch castVerb {
            case "start":
                method = "browser.screencast.start"
            case "stop":
                method = "browser.screencast.stop"
            default:
                throw CLIError(message: "Unsupported browser screencast subcommand: \(castVerb)")
            }
            let payload = try ctx.client.sendV2(method: method, params: ["surface_id": sid])
            ctx.output(payload, fallback: "OK")
            return true
        }

        return false
    }
}
