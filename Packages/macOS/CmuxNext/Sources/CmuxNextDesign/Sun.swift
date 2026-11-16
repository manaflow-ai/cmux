public import Foundation

/// Where the sun is in the sky: degrees above the horizon (negative below it) and compass bearing
/// (north 0, east 90).
public nonisolated struct SunPosition: Equatable, Sendable {
    public let altitude: Double
    public let azimuth: Double

    public init(altitude: Double, azimuth: Double) {
        self.altitude = altitude
        self.azimuth = azimuth
    }

    /// The angle between two sky positions, in degrees (great-circle distance).
    public func angle(to other: SunPosition) -> Double {
        let (a1, a2) = (altitude * .pi / 180, other.altitude * .pi / 180)
        let delta = (azimuth - other.azimuth) * .pi / 180
        let cosine = sin(a1) * sin(a2) + cos(a1) * cos(a2) * cos(delta)
        return acos(min(max(cosine, -1), 1)) * 180 / .pi
    }
}

/// One local day's sun events; nil for an event that does not happen that day (polar day or night).
public nonisolated struct SunEvents: Equatable, Sendable {
    /// Civil dawn and dusk: the sun 6 degrees below the horizon.
    public let dawn: Date?
    public let sunrise: Date?
    public let noon: Date
    public let sunset: Date?
    public let dusk: Date?
}

nonisolated extension SunPosition {
    /// The sun's altitude below which a dynamic picture shows its dark frame (civil dusk).
    public static let darkAltitude = -6.0

    /// Whether the sun is at or below ``darkAltitude``.
    public var isDark: Bool { altitude <= Self.darkAltitude }
}

/// The sun's position and the day's events by the NOAA solar calculator equations (Meeus): within
/// a minute for latitudes between the polar circles. Pure arithmetic, safe on any thread.
nonisolated extension BackdropLocation {
    /// The sun's position at `date` seen from here.
    public func sunPosition(at date: Date) -> SunPosition {
        let solar = Solar(date)
        let minutes = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 60
        let trueSolar = (minutes + solar.equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1_440)
        var hourAngle = trueSolar / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }
        let lat = latitude.radians, declination = solar.declination
        let cosZenith = min(max(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle.radians), -1), 1)
        let zenith = acos(cosZenith)
        let denominator = cos(lat) * sin(zenith)
        var azimuth = 180.0
        if abs(denominator) > 1e-9 {
            let cosAzimuth = min(max((sin(lat) * cosZenith - sin(declination)) / denominator, -1), 1)
            let angle = acos(cosAzimuth).degrees
            azimuth = hourAngle > 0 ? (angle + 180).truncatingRemainder(dividingBy: 360) : (540 - angle).truncatingRemainder(dividingBy: 360)
        }
        return SunPosition(altitude: 90 - zenith.degrees, azimuth: azimuth)
    }

    /// The sun events of the local day holding `date` in `calendar`'s time zone.
    public func sunEvents(on date: Date, calendar: Calendar) -> SunEvents {
        let start = calendar.startOfDay(for: date)
        // Solar noon of the UTC date nearest the local day's noon, refined once at its own instant.
        var noon = solarNoon(near: start.addingTimeInterval(12 * 3_600))
        noon = solarNoon(near: noon)
        func event(_ zenith: Double, rising: Bool) -> Date? {
            var guess = noon
            for _ in 0..<3 {
                guard let angle = Solar(guess).hourAngle(zenith: zenith, latitude: latitude) else { return nil }
                let offset = 4 * angle.degrees * 60
                let target = solarNoon(near: guess)
                guess = target.addingTimeInterval(rising ? -offset : offset)
            }
            return guess
        }
        return SunEvents(dawn: event(96, rising: true), sunrise: event(90.833, rising: true), noon: noon,
                         sunset: event(90.833, rising: false), dusk: event(96, rising: false))
    }

    /// Solar noon here on the UTC day of `date` (the equation of time read at `date`).
    private func solarNoon(near date: Date) -> Date {
        let day = (date.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400
        var minutes = 720 - 4 * longitude - Solar(date).equationOfTime
        // A longitude far from Greenwich puts the noon nearest `date` on the next or previous UTC day.
        let seconds = date.timeIntervalSince1970 - day
        if minutes * 60 - seconds > 43_200 { minutes -= 1_440 } else if seconds - minutes * 60 > 43_200 { minutes += 1_440 }
        return Date(timeIntervalSince1970: day + minutes * 60)
    }
}

/// The sun's declination (radians) and the equation of time (minutes) at one instant.
private nonisolated struct Solar {
    let declination: Double
    let equationOfTime: Double

    init(_ date: Date) {
        let century = (date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545) / 36_525
        let meanLongitude = (280.46646 + century * (36_000.76983 + century * 0.0003032)).truncatingRemainder(dividingBy: 360).radians
        let anomaly = (357.52911 + century * (35_999.05029 - 0.0001537 * century)).radians
        let eccentricity = 0.016708634 - century * (0.000042037 + 0.0000001267 * century)
        let center = sin(anomaly) * (1.914602 - century * (0.004817 + 0.000014 * century))
            + sin(2 * anomaly) * (0.019993 - 0.000101 * century) + sin(3 * anomaly) * 0.000289
        let omega = (125.04 - 1_934.136 * century).radians
        let apparent = meanLongitude + (center - 0.00569 - 0.00478 * sin(omega)).radians
        let meanObliquity = 23 + (26 + (21.448 - century * (46.815 + century * (0.00059 - century * 0.001813))) / 60) / 60
        let obliquity = (meanObliquity + 0.00256 * cos(omega)).radians
        declination = asin(sin(obliquity) * sin(apparent))
        let y = pow(tan(obliquity / 2), 2)
        equationOfTime = 4 * (y * sin(2 * meanLongitude) - 2 * eccentricity * sin(anomaly)
            + 4 * eccentricity * y * sin(anomaly) * cos(2 * meanLongitude)
            - 0.5 * y * y * sin(4 * meanLongitude) - 1.25 * eccentricity * eccentricity * sin(2 * anomaly)).degrees
    }

    /// The hour angle (radians) where the sun crosses `zenith` degrees at `latitude`; nil when it never does.
    func hourAngle(zenith: Double, latitude: Double) -> Double? {
        let lat = latitude.radians
        let cosine = cos(zenith.radians) / (cos(lat) * cos(declination)) - tan(lat) * tan(declination)
        guard cosine >= -1, cosine <= 1 else { return nil }
        return acos(cosine)
    }
}

private nonisolated extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
