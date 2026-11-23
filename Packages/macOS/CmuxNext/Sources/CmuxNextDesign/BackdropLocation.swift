public import Foundation

/// Where the sun events and a dynamic wallpaper's sun positions are read for
/// (`appearance.backgroundLocation`): degrees north and east. Unset, the system time zone's city
/// from the tz database's `zone.tab`, so cmux never asks for the person's location.
public nonisolated struct BackdropLocation: Equatable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Reads `"LAT,LON"` (`"37.77,-122.42"`, spaces allowed); nil for anything else or a value
    /// outside -90...90, -180...180.
    public init?(text: String) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let latitude = Double(parts[0]), let longitude = Double(parts[1]),
              latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }

    /// The tz database's table of time zones and their cities.
    public static let zoneTable = URL(fileURLWithPath: "/usr/share/zoneinfo/zone.tab")

    /// The coordinates of `timeZone`'s city in `zone.tab`. A zone the table does not list (UTC,
    /// an alias) stands on the equator at the longitude of its offset from GMT.
    public static func of(_ timeZone: TimeZone) -> BackdropLocation {
        if let city = zones[timeZone.identifier] { return city }
        return BackdropLocation(latitude: 0, longitude: Double(timeZone.secondsFromGMT()) / 240)
    }

    /// `zone.tab` read once per process, on first use (``prewarm()`` reads it off the main thread).
    private static let zones: [String: BackdropLocation] = {
        guard let text = try? String(contentsOf: zoneTable, encoding: .utf8) else { return [:] }
        return parseZoneTable(text)
    }()

    /// Reads ``zones`` on a background thread, so the first sun reading on the main thread finds it.
    public static func prewarm() {
        // task-owner: a one-shot read of a static table; nothing to cancel
        Task.detached(priority: .utility) { _ = Self.zones.count }
    }

    /// The rows of a `zone.tab`: `CC<TAB>±DDMM[SS]±DDDMM[SS]<TAB>Zone[<TAB>comment]`.
    static func parseZoneTable(_ text: String) -> [String: BackdropLocation] {
        var zones: [String: BackdropLocation] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let location = coordinates(String(fields[1])) else { continue }
            zones[String(fields[2])] = location
        }
        return zones
    }

    /// ISO 6709 `±DDMM±DDDMM` or `±DDMMSS±DDDMMSS`.
    static func coordinates(_ text: String) -> BackdropLocation? {
        guard let split = text.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        guard let latitude = angle(text[..<split], degreeDigits: 2), let longitude = angle(text[split...], degreeDigits: 3)
        else { return nil }
        return BackdropLocation(latitude: latitude, longitude: longitude)
    }

    private static func angle(_ text: Substring, degreeDigits: Int) -> Double? {
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(text.dropFirst())
        guard digits.count == degreeDigits + 2 || digits.count == degreeDigits + 4, digits.allSatisfy(\.isASCII),
              let degrees = Double(String(digits[..<degreeDigits])),
              let minutes = Double(String(digits[degreeDigits..<(degreeDigits + 2)])) else { return nil }
        let seconds = digits.count > degreeDigits + 2 ? Double(String(digits[(degreeDigits + 2)...])) ?? 0 : 0
        let value = degrees + minutes / 60 + seconds / 3_600
        return sign == "-" ? -value : value
    }
}
