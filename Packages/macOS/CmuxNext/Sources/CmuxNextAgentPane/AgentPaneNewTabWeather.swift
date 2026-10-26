public import Foundation

/// The New Tab weather widget's reading (`tabs.newTabWidgets.weather`): the current conditions and
/// today's high and low for one place, from Open-Meteo (keyless). The app fetches it
/// (`NewTabWeather` in CmuxNextApp) and every page context carries the last one; the page draws it
/// and dims it once it is older than ``maximumAge`` (the refresh failed: offline).
public nonisolated struct AgentPaneNewTabWeather: Codable, Sendable, Equatable {
    /// How long a reading stays current; the app refreshes after this.
    public static let maximumAge: TimeInterval = 30 * 60

    /// The place's name as Open-Meteo's geocoding names it ("Berlin").
    public var place: String
    /// The current temperature, in ``unit``.
    public var temperature: Double
    /// Today's high and low, in ``unit``.
    public var high: Double
    public var low: Double
    /// The WMO weather code (Open-Meteo `weather_code`): 0 clear, 1-3 cloudy, 45/48 fog, 51-67 rain,
    /// 71-77 snow, 80-86 showers, 95-99 thunder.
    public var code: Int
    /// "celsius" or "fahrenheit".
    public var unit: String
    /// When it was read, in milliseconds since 1970 (the page's clock).
    public var readAt: Double

    public init(place: String, temperature: Double, high: Double, low: Double, code: Int, unit: String, readAt: Date) {
        self.place = place
        self.temperature = temperature
        self.high = high
        self.low = low
        self.code = code
        self.unit = unit
        self.readAt = (readAt.timeIntervalSince1970 * 1000).rounded()
    }

    public func isCurrent(at now: Date) -> Bool {
        now.timeIntervalSince1970 * 1000 - readAt < Self.maximumAge * 1000
    }
}

nonisolated extension AgentPaneNewTabWeather {
    /// The unit this Mac's region reads temperatures in.
    public static func unit(for locale: Locale) -> String {
        locale.measurementSystem == .us ? "fahrenheit" : "celsius"
    }

    /// The place the widget shows without a city setting: the city of this Mac's time zone
    /// ("America/Los_Angeles" is "Los Angeles"), so it needs no location permission. nil for a
    /// zone with no city: UTC, GMT, Etc/..., and the old aliases whose last part is a region, not a
    /// city ("US/Pacific", "Canada/Eastern"), which would find the wrong place.
    public static func timeZoneCity(_ zone: TimeZone) -> String? {
        let parts = zone.identifier.split(separator: "/")
        guard parts.count >= 2, cityRegions.contains(String(parts[0])), let last = parts.last else { return nil }
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// The IANA areas whose zones end in a city.
    private static let cityRegions: Set<String> = [
        "Africa", "America", "Antarctica", "Arctic", "Asia", "Atlantic", "Australia", "Europe", "Indian", "Pacific",
    ]

    /// Open-Meteo's geocoding search for `city`: its first match.
    public static func geocodingURL(city: String) -> URL? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: city), URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    /// Open-Meteo's forecast at a place: the current temperature and code, and today's high and low.
    public static func forecastURL(latitude: Double, longitude: Double, unit: String) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)), URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "temperature_unit", value: unit),
        ]
        return components?.url
    }

    /// A geocoding answer's first place: its name and coordinates; nil when it found none.
    public static func place(fromGeocoding data: Data) -> (name: String, latitude: Double, longitude: Double)? {
        struct Answer: Decodable {
            struct Result: Decodable { var name: String; var latitude: Double; var longitude: Double }
            var results: [Result]?
        }
        guard let first = (try? JSONDecoder().decode(Answer.self, from: data))?.results?.first else { return nil }
        return (first.name, first.latitude, first.longitude)
    }

    /// A forecast answer as a reading; nil when a field is missing.
    public static func reading(fromForecast data: Data, place: String, unit: String, at date: Date) -> Self? {
        struct Answer: Decodable {
            struct Current: Decodable {
                var temperature: Double
                var code: Int
                enum CodingKeys: String, CodingKey { case temperature = "temperature_2m", code = "weather_code" }
            }
            struct Daily: Decodable {
                var high: [Double]
                var low: [Double]
                enum CodingKeys: String, CodingKey { case high = "temperature_2m_max", low = "temperature_2m_min" }
            }
            var current: Current
            var daily: Daily
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let high = answer.daily.high.first, let low = answer.daily.low.first else { return nil }
        return Self(place: place, temperature: answer.current.temperature, high: high, low: low,
                    code: answer.current.code, unit: unit, readAt: date)
    }
}
