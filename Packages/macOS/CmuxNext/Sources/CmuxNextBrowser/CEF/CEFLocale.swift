import Foundation

/// The embedded Chromium's UI locale (`CefSettings.locale`) and its
/// Accept-Language list (`accept_language_list`, the `intl.accept_languages`
/// preference, `navigator.languages`).
///
/// Chrome on macOS takes both from the system's preferred languages
/// (`NSLocale.preferredLanguages`), never from LANG/LC_* (a Finder or
/// `env -i` launch has none). The UI locale is the first preferred language
/// that Chromium ships a locale pak for, else en-US, so CEF always gets a
/// locale whose pak exists and never needs its own fallback.
nonisolated struct CEFLocale: Equatable, Sendable {
    /// Chromium locale name, for example `en-US`, `ja` or `zh-TW`.
    var locale: String
    /// Comma-separated language tags without spaces.
    var acceptLanguages: String

    static let fallback = "en-US"

    /// The locale for this process: the system's preferred languages against
    /// the locale paks in `frameworkDirectory/Resources`.
    static func current(frameworkDirectory: URL) -> CEFLocale {
        let resources = frameworkDirectory.appending(path: "Resources")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        return resolve(preferredLanguages: Locale.preferredLanguages, available: available(lprojNames: names))
    }

    static func resolve(preferredLanguages: [String], available: Set<String>) -> CEFLocale {
        var locale: String?
        var accept: [String] = []
        func append(_ tag: String) {
            if !accept.contains(tag) { accept.append(tag) }
        }
        for language in preferredLanguages {
            let parts = Parts(language)
            guard !parts.language.isEmpty else { continue }
            let chromium = parts.chromiumLocale
            let hasPak = available.contains(chromium)
            if locale == nil, hasPak { locale = chromium }
            // A language with a pak uses Chromium's name (macOS appends the
            // device region, "ja-US"); one without keeps its own tag.
            let tag = hasPak ? chromium : parts.tag
            append(tag)
            if tag != parts.language { append(parts.language) }
        }
        if accept.isEmpty {
            append(fallback)
            append("en")
        }
        return CEFLocale(locale: locale ?? fallback, acceptLanguages: accept.joined(separator: ","))
    }

    /// Chromium locale names of the `.lproj` directories in the framework's
    /// Resources directory: `en` is en-US, `zh_TW` is zh-TW. Gendered
    /// variants (`ja_NEUTER`) and pseudo-locales (`en_XA`, `ar_XB`) are not
    /// UI locales.
    static func available(lprojNames: [String]) -> Set<String> {
        var result: Set<String> = []
        for name in lprojNames where name.hasSuffix(".lproj") {
            let base = String(name.dropLast(".lproj".count))
            let parts = base.split(separator: "_").map(String.init)
            guard let language = parts.first, !language.isEmpty else { continue }
            if parts.contains(where: { ["FEMININE", "MASCULINE", "NEUTER", "XA", "XB"].contains($0) }) { continue }
            if base == "en" {
                result.insert("en-US")
            } else {
                result.insert(parts.joined(separator: "-"))
            }
        }
        return result
    }

    /// A BCP 47 tag from `preferredLanguages`: `zh-Hant-US`, `en-GB`, `ja`.
    private struct Parts {
        var language: String
        var script: String?
        var region: String?

        init(_ tag: String) {
            let pieces = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            language = pieces.first?.lowercased() ?? ""
            for piece in pieces.dropFirst() {
                if piece.count == 4, script == nil {
                    script = piece.capitalized
                } else if region == nil, piece.count == 2 || (piece.count == 3 && piece.allSatisfy(\.isNumber)) {
                    region = piece.uppercased()
                }
            }
        }

        /// The tag without script: `en-GB`, `ja`, `km-KH`.
        var tag: String {
            region.map { "\(language)-\($0)" } ?? language
        }

        /// Chromium's locale for this language (l10n_util's mapping).
        var chromiumLocale: String {
            switch language {
            case "zh":
                if script == "Hant" || ["TW", "HK", "MO"].contains(region ?? "") { return "zh-TW" }
                return "zh-CN"
            case "en":
                let british: Set<String> = ["GB", "AU", "CA", "IE", "IN", "NZ", "ZA"]
                return british.contains(region ?? "") ? "en-GB" : "en-US"
            case "es":
                return region == nil || region == "ES" ? "es" : "es-419"
            case "pt":
                return region == "PT" ? "pt-PT" : "pt-BR"
            case "no", "nn":
                return "nb"
            case "iw":
                return "he"
            case "tl":
                return "fil"
            default:
                return language
            }
        }
    }
}
