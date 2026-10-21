import CmuxNextAgentPane
import CmuxNextSettings
import Foundation

/// The New Tab weather widget's source (`tabs.newTabWidgets.weather`): it keeps the last reading
/// (in memory and in UserDefaults, so an offline launch still shows it, dimmed) and refreshes it from
/// Open-Meteo once it is older than ``AgentPaneNewTabWeather/maximumAge``. Nothing is fetched until
/// the widget is on. The place is `tabs.newTabWidgets.weatherCity`, else this Mac's time zone city.
@MainActor final class NewTabWeather {
    static let shared = NewTabWeather()

    private struct Stored: Codable {
        /// The place asked for and the unit: a reading for another city or unit is not shown.
        var key: String
        var reading: AgentPaneNewTabWeather
    }

    private static let defaultsKey = "cmux.newTab.weather"
    private var stored: Stored?
    private var refreshing: String?
    /// When the last refresh for a place failed, so an offline Mac does not ask on every new tab;
    /// another place asks at once.
    private var failed: (key: String, at: Date)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey) {
            stored = try? JSONDecoder().decode(Stored.self, from: data)
        }
    }

    /// The reading for the settings' place, starting a refresh when it is missing or old; nil while
    /// the widget is off or no reading for that place has arrived yet.
    func reading(_ widgets: NewTabWidgetSettings, now: Date = Date()) -> AgentPaneNewTabWeather? {
        guard widgets.weather,
              let city = widgets.weatherCity.isEmpty ? AgentPaneNewTabWeather.timeZoneCity(.current) : widgets.weatherCity
        else { return nil }
        let unit = AgentPaneNewTabWeather.unit(for: .current)
        let key = "\(city)|\(unit)"
        let reading = stored?.key == key ? stored?.reading : nil
        let retryAfter = failed.map { $0.key != key || now.timeIntervalSince($0.at) > 60 } ?? true
        if reading?.isCurrent(at: now) != true, refreshing != key, retryAfter {
            refresh(city: city, unit: unit, key: key)
        }
        return reading
    }

    private func refresh(city: String, unit: String, key: String) {
        refreshing = key
        Task { [weak self] in
            let reading = await Self.fetch(city: city, unit: unit)
            guard let self else { return }
            refreshing = nil
            guard let reading else {
                failed = (key, Date())
                return
            }
            failed = nil
            let stored = Stored(key: key, reading: reading)
            self.stored = stored
            if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
        }
    }

    /// Geocodes `city` and reads its forecast; nil on any failure (offline, no such city).
    private nonisolated static func fetch(city: String, unit: String) async -> AgentPaneNewTabWeather? {
        guard let geocoding = AgentPaneNewTabWeather.geocodingURL(city: city),
              let (placeData, _) = try? await URLSession.shared.data(from: geocoding),
              let place = AgentPaneNewTabWeather.place(fromGeocoding: placeData),
              let forecast = AgentPaneNewTabWeather.forecastURL(latitude: place.latitude, longitude: place.longitude, unit: unit),
              let (data, _) = try? await URLSession.shared.data(from: forecast)
        else { return nil }
        return AgentPaneNewTabWeather.reading(fromForecast: data, place: place.name, unit: unit, at: Date())
    }
}

extension AgentPaneNewTab {
    /// The page with the weather widget's last reading (nil while the widget is off).
    @MainActor func withWeather(_ services: AppServices) -> AgentPaneNewTab {
        guard let widgets = services.settings?.snapshot.newTabWidgets else { return self }
        var page = self
        page.weather = NewTabWeather.shared.reading(widgets)
        return page
    }
}
