import Foundation

enum GhosttyCrashReportMetadata {
    static func reportedExecutablePaths(in url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let event = sentryEvent(from: data),
              let debugMeta = event["debug_meta"] as? [String: Any],
              let images = debugMeta["images"] as? [[String: Any]]
        else {
            return nil
        }

        let paths = images.compactMap { image -> String? in
            guard let codeFile = image["code_file"] as? String else { return nil }
            let trimmedPath = codeFile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { return nil }
            return normalizedPath(trimmedPath)
        }
        return paths.isEmpty ? nil : Set(paths)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func sentryEvent(from data: Data) -> [String: Any]? {
        guard let envelopeHeaderRange = lineRange(after: data.startIndex, in: data) else {
            return nil
        }

        var itemHeaderStart = data.index(after: envelopeHeaderRange.upperBound)
        while itemHeaderStart < data.endIndex {
            guard let itemHeaderRange = lineRange(after: itemHeaderStart, in: data),
                  let itemHeader = jsonObject(in: itemHeaderRange, from: data)
            else {
                return nil
            }

            let payloadStart = data.index(after: itemHeaderRange.upperBound)
            let payloadRange: Range<Data.Index>
            if let length = itemHeader["length"] as? Int {
                guard length >= 0,
                      let payloadEnd = data.index(payloadStart, offsetBy: length, limitedBy: data.endIndex)
                else {
                    return nil
                }
                payloadRange = payloadStart..<payloadEnd
                itemHeaderStart = payloadEnd
                if itemHeaderStart < data.endIndex, data[itemHeaderStart] == 0x0A {
                    itemHeaderStart = data.index(after: itemHeaderStart)
                }
            } else {
                guard let lineRange = lineRange(after: payloadStart, in: data) else {
                    return nil
                }
                payloadRange = lineRange
                itemHeaderStart = data.index(after: lineRange.upperBound)
            }

            if itemHeader["type"] as? String == "event" {
                return jsonObject(in: payloadRange, from: data)
            }
        }

        return nil
    }

    private static func lineRange(after startIndex: Data.Index, in data: Data) -> Range<Data.Index>? {
        guard startIndex < data.endIndex,
              let newlineIndex = data[startIndex...].firstIndex(of: 0x0A)
        else {
            return nil
        }
        return startIndex..<newlineIndex
    }

    private static func jsonObject(in range: Range<Data.Index>, from data: Data) -> [String: Any]? {
        guard range.lowerBound <= range.upperBound else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data.subdata(in: range)) else {
            return nil
        }
        return object as? [String: Any]
    }
}

extension GhosttyCrashReportMetadata {
    /// Crash summary parsed from a `.ghosttycrash` Sentry envelope, used to
    /// mirror the crash into PostHog Error Tracking as an `$exception`. All
    /// fields are best effort; native envelopes may only have a minidump.
    struct ReportedException: Equatable, Sendable {
        /// Sentry exception type, e.g. `EXC_BAD_ACCESS` or an NSException name.
        let type: String
        /// System-generated reason string, e.g. `KERN_INVALID_ADDRESS at 0x0`.
        let value: String?
        /// Sentry mechanism type, e.g. `mach`, `signal`, or `NSException`.
        let mechanismType: String?
        /// Version of the build that crashed, from the envelope's app context.
        let appVersion: String?
        /// Build number of the build that crashed.
        let appBuild: String?
        /// Bundle identifier of the crashed build, e.g. `com.cmuxterm.app`.
        let appNamespace: String?
    }

    /// Reads the exception and app context out of a crash envelope. Returns
    /// nil when the envelope has no parseable event payload.
    static func reportedException(in url: URL) -> ReportedException? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let event = sentryEvent(from: data)
        else {
            return nil
        }
        // Sentry orders exception values oldest first; the last one is the
        // crash that terminated the process.
        let values = (event["exception"] as? [String: Any])?["values"] as? [[String: Any]]
        let crash = values?.last ?? [:]
        let type = crash["type"] as? String ?? "UnknownCrash"
        let mechanism = crash["mechanism"] as? [String: Any]
        let appContext = (event["contexts"] as? [String: Any])?["app"] as? [String: Any]
        return ReportedException(
            type: type,
            value: crash["value"] as? String,
            mechanismType: mechanism?["type"] as? String,
            appVersion: appContext?["app_version"] as? String,
            appBuild: appContext?["app_build"] as? String,
            appNamespace: appContext?["app_identifier"] as? String
        )
    }
}
