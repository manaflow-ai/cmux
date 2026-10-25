@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The New Tab weather widget's place without a city setting: the city of this Mac's time zone,
/// never a region alias's last word ("US/Pacific" is not a city named Pacific).
struct AgentPaneNewTabWeatherTests {
    @Test func timeZoneCityIsTheZonesCity() throws {
        let zone = { (id: String) in try #require(TimeZone(identifier: id)) }
        #expect(AgentPaneNewTabWeather.timeZoneCity(try zone("America/Los_Angeles")) == "Los Angeles")
        #expect(AgentPaneNewTabWeather.timeZoneCity(try zone("Europe/Berlin")) == "Berlin")
        #expect(AgentPaneNewTabWeather.timeZoneCity(try zone("America/Argentina/Buenos_Aires")) == "Buenos Aires")
        #expect(AgentPaneNewTabWeather.timeZoneCity(try zone("Pacific/Auckland")) == "Auckland")
    }

    @Test func zonesWithNoCityHaveNoPlace() throws {
        for id in ["UTC", "GMT", "Etc/GMT+5", "US/Pacific", "Canada/Eastern"] {
            guard let zone = TimeZone(identifier: id) else { continue }
            #expect(AgentPaneNewTabWeather.timeZoneCity(zone) == nil, "\(id)")
        }
    }
}
