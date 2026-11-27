import Foundation
import Testing
@testable import CmuxMobileModel

@Suite struct MacNameDisambiguationTests {
    @Test func uniqueNamesGetNoTag() {
        let names = MacNameDisambiguation([
            MacDevice(id: "a1b2c3d4", name: "Aziz's Mac Studio", isOnline: true),
            MacDevice(id: "e5f6a7b8", name: "Aziz's MacBook Pro", isOnline: false),
        ])
        #expect(names.tags.isEmpty)
        #expect(names.displayName(id: "e5f6a7b8", name: "Aziz's MacBook Pro") == "Aziz's MacBook Pro")
        #expect(names.added(for: "e5f6a7b8", addedAt: Date()) == nil)
    }

    @Test func collidingNamesAreTaggedByIdEnding() {
        let names = MacNameDisambiguation([
            MacDevice(id: "mac-0001-3f2a", name: "Aziz's MacBook Pro", isOnline: true),
            MacDevice(id: "mac-0002-91c7", name: "Aziz's MacBook Pro", isOnline: false),
            MacDevice(id: "mac-0003-aaaa", name: "Aziz's Mac Studio", isOnline: true),
        ])
        #expect(names.tag(for: "mac-0001-3f2a") == "3F2A")
        #expect(names.tag(for: "mac-0002-91c7") == "91C7")
        #expect(names.tag(for: "mac-0003-aaaa") == nil)
        #expect(names.displayName(id: "mac-0002-91c7", name: "Aziz's MacBook Pro") == "Aziz's MacBook Pro 91C7")
        #expect(names.displayName(id: "mac-0003-aaaa", name: "Aziz's Mac Studio") == "Aziz's Mac Studio")
    }

    @Test func caseAndSpacesDoNotHideACollision() {
        let names = MacNameDisambiguation([(id: "x-1111", name: "MacBook Pro"), (id: "y-2222", name: " macbook pro ")])
        #expect(names.tag(for: "x-1111") == "1111")
        #expect(names.tag(for: "y-2222") == "2222")
    }

    @Test func tagGrowsUntilCollidingIdsDiffer() {
        let names = MacNameDisambiguation([(id: "aa-9-beef", name: "Mac"), (id: "bb-8-beef", name: "Mac")])
        #expect(names.tag(for: "aa-9-beef") == "9BEEF")
        #expect(names.tag(for: "bb-8-beef") == "8BEEF")
    }

    @Test func theSameMacListedTwiceIsNotACollision() {
        let names = MacNameDisambiguation([(id: "m-1234", name: "Mac"), (id: "m-1234", name: "Mac")])
        #expect(names.tags.isEmpty)
    }

    @Test func addedSaysWhenAddedWhenKnown() throws {
        let names = MacNameDisambiguation([(id: "m-1111", name: "Mac"), (id: "m-2222", name: "Mac")])
        #expect(names.added(for: "m-1111", addedAt: nil) == nil)
        let added = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12)))
        let detail = try #require(names.added(for: "m-2222", addedAt: added))
        #expect(detail.hasPrefix("Added "))
        #expect(!detail.contains("ID"))
    }

    @Test func accountScopeTagsAMacWhoseNamesakeIsInAnotherTeam() {
        let teams = [
            Team(id: "t1", name: "One", macs: [MacDevice(id: "aaaa-3f2a", name: "MacBook Pro", isOnline: true)]),
            Team(id: "t2", name: "Two", macs: [MacDevice(id: "bbbb-91c7", name: "MacBook Pro", isOnline: false)]),
        ]
        let names = MacNameDisambiguation(account: teams)
        #expect(names.displayName(id: "aaaa-3f2a", name: "MacBook Pro") == "MacBook Pro 3F2A")
        #expect(names.displayName(id: "bbbb-91c7", name: "MacBook Pro") == "MacBook Pro 91C7")
    }
}
