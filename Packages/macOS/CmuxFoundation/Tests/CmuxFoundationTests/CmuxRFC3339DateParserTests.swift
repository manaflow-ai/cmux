import Foundation
import Testing

@testable import CmuxFoundation

@Suite("RFC 3339 date parser")
struct CmuxRFC3339DateParserTests {
  @Test("accepts server and legacy timestamp precision")
  func acceptsFractionalAndWholeSeconds() {
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00.000Z") != nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00Z") != nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00.123456789Z") != nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00+05:30") != nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00.5-07:00") != nil)
  }

  @Test("rejects timestamps without a time zone")
  func rejectsMissingTimeZone() {
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00.1") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "not-a-date") == nil)
  }

  @Test("rejects non-canonical timezone and whitespace spellings")
  func rejectsNonCanonicalSpellings() {
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00+0530") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00Z ") == nil)
    #expect(CmuxRFC3339DateParser.date(from: " 2099-01-01T00:00:00Z") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00z") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01 00:00:00Z") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T00:00:00.1234567890Z") == nil)
  }

  @Test("rejects normalized calendar and offset overflow")
  func rejectsOutOfRangeComponents() {
    #expect(CmuxRFC3339DateParser.date(from: "2099-02-30T00:00:00Z") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T24:00:00Z") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T23:60:00Z") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T23:59:60Z") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2099-01-01T23:59:59+00:60") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2100-02-29T00:00:00Z") == nil)
    #expect(CmuxRFC3339DateParser.date(from: "2000-02-29T00:00:00Z") != nil)
  }
}
