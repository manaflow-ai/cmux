public import Foundation

/// A public-domain work found in a museum's open-access collection (cx-t2x.8, "Browse more art").
public nonisolated struct MuseumArtResult: Sendable, Equatable {
    /// `<source>:<the museum's id>`, unique across sources.
    public let key: String
    public let source: MuseumArtSource
    public let title: String
    public let artist: String
    public let date: String
    /// A small image for the result grid.
    public let thumbnail: URL
    /// The image the background downloads (a few thousand pixels wide at most).
    public let image: URL
    /// The work's page at the museum, with its license.
    public let page: URL

    package init(key: String, source: MuseumArtSource, title: String, artist: String, date: String, thumbnail: URL, image: URL, page: URL) {
        self.key = key
        self.source = source
        self.title = title
        self.artist = artist
        self.date = date
        self.thumbnail = thumbnail
        self.image = image
        self.page = page
    }
}

/// The open-access collections the browser searches: each serves public-domain works with images
/// and no API key. (The Met's search answers 410 Gone and the Rijksmuseum needs a key, so they wait.)
public nonisolated enum MuseumArtSource: String, CaseIterable, Sendable {
    case artInstitute = "aic"
    case cleveland
    case commons

    /// The collection's name (a proper name, the same in every language).
    public var name: String {
        switch self {
        case .artInstitute: "Art Institute of Chicago"
        case .cleveland: "Cleveland Museum of Art"
        case .commons: "Wikimedia Commons"
        }
    }

    /// The hosts this source's images come from; nothing else is fetched for a result.
    package var imageHosts: Set<String> {
        switch self {
        case .artInstitute: ["www.artic.edu"]
        case .cleveland: ["openaccess-cdn.clevelandart.org"]
        case .commons: ["upload.wikimedia.org", "thumb.wikimedia.org"]
        }
    }
}

/// Searches the open-access collections for public-domain works with images. Every source is asked
/// at once; one that fails or answers late leaves the others' results.
public nonisolated struct MuseumArtSearch: Sendable {
    private let fetch: @Sendable (URL) async throws -> Data

    /// - Parameter fetch: Reads a URL's body (tests inject recorded answers).
    public init(fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.fetch = fetch
    }

    /// The live collections over HTTPS, identifying cmux as Wikimedia asks of API clients.
    public static let live = MuseumArtSearch { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("cmux/1.0 (https://cmux.com/art)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Up to `limit` works per source matching `query`, interleaved so every source shows near the top.
    public func search(_ query: String, limit: Int = 12) async -> [MuseumArtResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let fetch = fetch
        var bySource: [MuseumArtSource: [MuseumArtResult]] = [:]
        await withTaskGroup(of: (MuseumArtSource, [MuseumArtResult]).self) { group in
            for source in MuseumArtSource.allCases {
                guard let url = Self.searchURL(source, query: query, limit: limit) else { continue }
                group.addTask {
                    guard let data = try? await fetch(url) else { return (source, []) }
                    return (source, Array(Self.results(source, from: data).prefix(limit)))
                }
            }
            for await (source, results) in group { bySource[source] = results }
        }
        let lists = MuseumArtSource.allCases.map { bySource[$0] ?? [] }
        var interleaved: [MuseumArtResult] = []
        for index in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where index < list.count { interleaved.append(list[index]) }
        }
        return interleaved
    }

    /// The bytes at `url` when it is one of `result`'s images, else nil (a page cannot make cmux
    /// fetch anything else through a result).
    public func image(_ url: URL, of result: MuseumArtResult) async -> Data? {
        guard url == result.image || url == result.thumbnail, Self.isAllowed(url, for: result.source) else { return nil }
        return try? await fetch(url)
    }

    package static func isAllowed(_ url: URL, for source: MuseumArtSource) -> Bool {
        url.scheme == "https" && url.host.map(source.imageHosts.contains) == true
    }

    package static func searchURL(_ source: MuseumArtSource, query: String, limit: Int) -> URL? {
        var components: URLComponents?
        switch source {
        case .artInstitute:
            components = URLComponents(string: "https://api.artic.edu/api/v1/artworks/search")
            components?.queryItems = [
                .init(name: "q", value: query), .init(name: "query[term][is_public_domain]", value: "true"),
                .init(name: "fields", value: "id,title,artist_title,date_display,image_id,is_public_domain"),
                .init(name: "limit", value: String(limit)),
            ]
        case .cleveland:
            components = URLComponents(string: "https://openaccess-api.clevelandart.org/api/artworks/")
            components?.queryItems = [
                .init(name: "q", value: query), .init(name: "cc0", value: "1"), .init(name: "has_image", value: "1"),
                .init(name: "limit", value: String(limit)),
                .init(name: "fields", value: "id,title,creators,creation_date,images,url,share_license_status"),
            ]
        case .commons:
            // Files whose copyright status (P6216) is public domain (Q19652).
            components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
            components?.queryItems = [
                .init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "generator", value: "search"),
                .init(name: "gsrnamespace", value: "6"), .init(name: "gsrsearch", value: "\(query) haswbstatement:P6216=Q19652"),
                .init(name: "gsrlimit", value: String(limit)), .init(name: "prop", value: "imageinfo"),
                .init(name: "iiprop", value: "url|extmetadata|mime"), .init(name: "iiurlwidth", value: "2400"),
                .init(name: "iiextmetadatafilter", value: "LicenseShortName|Artist|ObjectName|DateTimeOriginal"),
            ]
        }
        return components?.url
    }
}
