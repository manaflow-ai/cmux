import CmuxNextAgentPane
import CmuxNextSettings
import Foundation

/// The New Tab weather widget's source (`tabs.newTabWidgets.weather`): it keeps the last reading
/// (in memory and in UserDefaults, so an offline launch still shows it, dimmed) and refreshes it from
/// Open-Meteo once it is older than ``AgentPaneNewTabWeather/maximumAge``. Nothing is fetched until
/// the widget is on. The place is `tabs.newTabWidgets.weatherCity`, else this Mac's time zone city.
/// One per app (``AppServices/newTabWeather``).
@MainActor final class NewTabWeather {
    private struct Stored: Codable {
        /// The place asked for and the unit: a reading for another city or unit is not shown.
        var key: String
        var reading: AgentPaneNewTabWeather
    }

    private static let defaultsKey = "cmux.newTab.weather"
    private var stored: Stored?
    private var refreshing: String?
    /// The place the last page context asked for: only its refresh fills the cache.
    private var wanted: String?
    /// Called when a refresh brought a new reading (``wire(_:services:)``: the open pages take it).
    private var onReading: (@MainActor () -> Void)?
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
        guard let place = Self.place(widgets) else { return nil }
        wanted = place.key
        let reading = stored?.key == place.key ? stored?.reading : nil
        let retryAfter = failed.map { $0.key != place.key || now.timeIntervalSince($0.at) > 60 } ?? true
        if reading?.isCurrent(at: now) != true, refreshing != place.key, retryAfter {
            refresh(city: place.city, unit: place.unit, key: place.key)
        }
        return reading
    }

    /// The last reading for the settings' place, starting nothing; nil while the widget is off.
    func lastReading(_ widgets: NewTabWidgetSettings) -> AgentPaneNewTabWeather? {
        guard let place = Self.place(widgets), stored?.key == place.key else { return nil }
        return stored?.reading
    }

    /// The place the settings ask for and the unit, as the cache key; nil while the widget is off or
    /// there is no city (no setting and a time zone with no city).
    private static func place(_ widgets: NewTabWidgetSettings) -> (city: String, unit: String, key: String)? {
        guard widgets.weather,
              let city = widgets.weatherCity.isEmpty ? AgentPaneNewTabWeather.timeZoneCity(.current) : widgets.weatherCity
        else { return nil }
        let unit = AgentPaneNewTabWeather.unit(for: .current)
        return (city, unit, "\(city)|\(unit)")
    }

    private func refresh(city: String, unit: String, key: String) {
        refreshing = key
        Task { [weak self] in
            let reading = await Self.fetch(city: city, unit: unit)
            guard let self else { return }
            // A refresh for a place the settings no longer ask for (the city changed meanwhile)
            // neither clears the newer refresh's mark nor replaces the cache.
            if refreshing == key { refreshing = nil }
            guard wanted == key else { return }
            guard let reading else {
                failed = (key, Date())
                return
            }
            failed = nil
            let stored = Stored(key: key, reading: reading)
            self.stored = stored
            if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
            onReading?()
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

extension NewTabWeather {
    /// Every open New Tab page takes a reading when a refresh brings one, in place
    /// (``AgentPaneView/refreshNewTabWeather(_:)``): a page opened before the first reading, or with
    /// an old one, does not wait for the next New Tab to show it. Runs only when a refresh
    /// finishes, and a refresh starts only while the widget is on.
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        services.newTabWeather.onReading = { [weak tabs, weak services] in
            guard let tabs, let services, let widgets = services.settings?.snapshot.newTabWidgets else { return }
            let reading = services.newTabWeather.lastReading(widgets)
            for key in tabs.newTabPages.keys { tabs.views[key]?.refreshNewTabWeather(reading) }
        }
    }
}

extension AgentPaneNewTab {
    /// The page with the weather widget's last reading (nil while the widget is off).
    @MainActor func withWeather(_ services: AppServices) -> AgentPaneNewTab {
        guard let widgets = services.settings?.snapshot.newTabWidgets else { return self }
        var page = self
        page.weather = services.newTabWeather.reading(widgets)
        return page
    }
}
