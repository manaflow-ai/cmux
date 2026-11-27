package import Foundation

/// Each collection's answer, read into results. Only works the collection marks public domain
/// (CC0 at Cleveland), with an image on one of the source's own hosts, are kept.
nonisolated extension MuseumArtSearch {
    package static func results(_ source: MuseumArtSource, from data: Data) -> [MuseumArtResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let found: [MuseumArtResult?]
        switch source {
        case .artInstitute: found = artInstitute(json)
        case .cleveland: found = cleveland(json)
        case .commons: found = commons(json)
        }
        return found.compactMap { result in
            guard let result, isAllowed(result.image, for: source), isAllowed(result.thumbnail, for: source) else { return nil }
            return result
        }
    }

    private static func artInstitute(_ json: [String: Any]) -> [MuseumArtResult?] {
        let iiif = ((json["config"] as? [String: Any])?["iiif_url"] as? String) ?? "https://www.artic.edu/iiif/2"
        return ((json["data"] as? [[String: Any]]) ?? []).map { work in
            guard work["is_public_domain"] as? Bool == true, let id = work["id"] as? Int,
                  let imageID = work["image_id"] as? String, !imageID.isEmpty, !imageID.contains("/"),
                  let title = text(work["title"]),
                  let thumbnail = URL(string: "\(iiif)/\(imageID)/full/400,/0/default.jpg"),
                  let image = URL(string: "\(iiif)/\(imageID)/full/1686,/0/default.jpg"),
                  let page = URL(string: "https://www.artic.edu/artworks/\(id)") else { return nil }
            return MuseumArtResult(key: "\(MuseumArtSource.artInstitute.rawValue):\(id)", source: .artInstitute, title: title,
                                   artist: text(work["artist_title"]) ?? "", date: text(work["date_display"]) ?? "",
                                   thumbnail: thumbnail, image: image, page: page)
        }
    }

    private static func cleveland(_ json: [String: Any]) -> [MuseumArtResult?] {
        ((json["data"] as? [[String: Any]]) ?? []).map { work in
            let images = work["images"] as? [String: Any]
            func url(_ size: String) -> URL? {
                ((images?[size] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:))
            }
            guard work["share_license_status"] as? String == "CC0", let id = work["id"] as? Int,
                  let title = text(work["title"]), let thumbnail = url("web"),
                  let page = (work["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            // "Salvator Rosa (Italian, 1615–1673)": the name, without the note.
            let creator = ((work["creators"] as? [[String: Any]])?.first?["description"] as? String) ?? ""
            let artist = creator.components(separatedBy: " (").first ?? creator
            return MuseumArtResult(key: "\(MuseumArtSource.cleveland.rawValue):\(id)", source: .cleveland, title: title,
                                   artist: artist, date: text(work["creation_date"]) ?? "",
                                   thumbnail: thumbnail, image: url("print") ?? thumbnail, page: page)
        }
    }

    private static func commons(_ json: [String: Any]) -> [MuseumArtResult?] {
        let pages = ((json["query"] as? [String: Any])?["pages"] as? [String: Any]) ?? [:]
        return pages.values.compactMap { $0 as? [String: Any] }
            .sorted { ($0["index"] as? Int ?? .max) < ($1["index"] as? Int ?? .max) }
            .map { page in
                guard let id = page["pageid"] as? Int, let name = page["title"] as? String,
                      let info = (page["imageinfo"] as? [[String: Any]])?.first,
                      (info["mime"] as? String).map({ ["image/jpeg", "image/png", "image/tiff"].contains($0) }) ?? true,
                      let full = (info["thumburl"] as? String ?? info["url"] as? String).flatMap(URL.init(string:)),
                      let described = (info["descriptionurl"] as? String).flatMap(URL.init(string:)) else { return nil }
                let metadata = (info["extmetadata"] as? [String: Any]) ?? [:]
                func field(_ key: String) -> String? { text((metadata[key] as? [String: Any])?["value"]) }
                guard field("LicenseShortName")?.localizedCaseInsensitiveContains("public domain") == true else { return nil }
                let thumbnail = commonsThumbnail(of: full) ?? full
                let fileTitle = URL(fileURLWithPath: String(name.dropFirst("File:".count))).deletingPathExtension().lastPathComponent
                return MuseumArtResult(key: "\(MuseumArtSource.commons.rawValue):\(id)", source: .commons,
                                       title: field("ObjectName") ?? fileTitle, artist: field("Artist") ?? "",
                                       date: field("DateTimeOriginal") ?? "", thumbnail: thumbnail, image: full, page: described)
            }
    }

    /// A 500-pixel Commons thumbnail of `url`. Commons answers the nearest standard width
    /// (".../thumb/a/ab/Name/3840px-Name") or, for a smaller file, the original
    /// (".../commons/a/ab/Name"), and serves only standard widths.
    package static func commonsThumbnail(of url: URL) -> URL? {
        let text = url.absoluteString
        if text.contains("/thumb/") {
            return URL(string: text.replacingOccurrences(of: "/[0-9]+px-", with: "/500px-", options: .regularExpression))
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, let name = parts.last,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        var path: [String] = Array(parts.dropLast(3))
        path.append("thumb")
        path.append(contentsOf: parts.suffix(3))
        path.append("500px-\(name)")
        components.path = "/" + path.joined(separator: "/")
        return components.url
    }

    /// Plain text from an API value: Commons metadata is HTML (links, hidden date markup), so tags
    /// and anything after a hidden "date QS" note go, whitespace collapses, and length is capped.
    package static func text(_ value: Any?) -> String? {
        guard var text = value as? String else { return nil }
        if let hidden = text.range(of: "<div style=\"display: none;\">") { text = String(text[..<hidden.lowerBound]) }
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&#0*39;", with: "'", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > 120 ? String(text.prefix(119)) + "…" : text
    }
}
