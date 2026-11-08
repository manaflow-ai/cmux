import Foundation
import Testing

@testable import CmuxBrowser

/// Domain filtering for browser import: the set-based filter must keep the
/// matching rule the importers used before it.
@Suite struct BrowserImportDomainFilterTests {
    /// The importers' previous rule, kept here as the oracle: a host matches a
    /// filter when it equals it or ends with `.` followed by it.
    private static func referenceMatches(host: String, filters: [String]) -> Bool {
        if filters.isEmpty { return true }
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalizedHost.hasPrefix(".") {
            normalizedHost.removeFirst()
        }
        guard !normalizedHost.isEmpty else { return false }
        for filter in filters {
            if normalizedHost == filter { return true }
            if normalizedHost.hasSuffix(".\(filter)") { return true }
        }
        return false
    }

    @Test func anEmptyFilterListMatchesEveryHost() {
        let filter = BrowserImportDomainFilter(filters: [])

        #expect(filter.matches(host: "example.com"))
        #expect(filter.matches(host: ""))
    }

    @Test func matchesTheDomainAndItsSubdomainsOnly() {
        let filter = BrowserImportDomainFilter(filters: ["example.com"])

        #expect(filter.matches(host: "example.com"))
        #expect(filter.matches(host: ".example.com"))
        #expect(filter.matches(host: "a.b.example.com"))
        #expect(filter.matches(host: " Login.EXAMPLE.com "))
        #expect(!filter.matches(host: "notexample.com"))
        #expect(!filter.matches(host: "example.com.evil.net"))
        #expect(!filter.matches(host: "com"))
        #expect(!filter.matches(host: "..."))
    }

    @Test func agreesWithThePreviousRuleOnEveryCombination() {
        let filterSets: [[String]] = [
            [],
            ["example.com"],
            ["com"],
            ["example.com", "github.io"],
            ["b.example.com", "x.y"],
            [".example.com"],
            [""],
            ["Example.com"],
        ]
        let hosts = [
            "", ".", "...", "com", "example.com", ".example.com", "..example.com",
            "a.example.com", "a.b.example.com", "b.example.com", "ab.example.com",
            "notexample.com", "example.com.", "example.com.evil.net", " EXAMPLE.com ",
            "user.github.io", "github.io", "x.y", "w.x.y", "xx.y", "a..b",
        ]

        for filters in filterSets {
            let filter = BrowserImportDomainFilter(filters: filters)
            for host in hosts {
                #expect(
                    filter.matches(host: host) == Self.referenceMatches(host: host, filters: filters),
                    "host \(host.debugDescription) filters \(filters)"
                )
            }
        }
    }
}
