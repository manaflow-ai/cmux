public import Foundation

/// Parses the canonical RFC 3339 timestamp forms used by cmux HTTP protocols.
///
/// JavaScript `Date.toISOString()` always includes fractional seconds. Some
/// older protocol fixtures omit them. Keep both forms valid so clients do not
/// reject a real server response because its timestamp is more precise than a
/// test fixture.
public enum CmuxRFC3339DateParser {
  public static func date(from value: String) -> Date? {
    // Date.ISO8601FormatStyle is intentionally permissive. It accepts
    // offsets without a colon and ignores trailing whitespace, while the
    // handoff contract uses the canonical RFC 3339 spelling only:
    // `YYYY-MM-DDTHH:mm:ss[.fraction](Z|+/-HH:mm)`.
    let bytes = Array(value.utf8)
    guard bytes.count >= 20,
      isDigits(bytes, in: 0..<4),
      bytes[4] == 45,
      isDigits(bytes, in: 5..<7),
      bytes[7] == 45,
      isDigits(bytes, in: 8..<10),
      bytes[10] == 84,
      isDigits(bytes, in: 11..<13),
      bytes[13] == 58,
      isDigits(bytes, in: 14..<16),
      bytes[16] == 58,
      isDigits(bytes, in: 17..<19)
    else {
      return nil
    }

    let year = decimal(bytes, in: 0..<4)
    let month = decimal(bytes, in: 5..<7)
    let day = decimal(bytes, in: 8..<10)
    let hour = decimal(bytes, in: 11..<13)
    let minute = decimal(bytes, in: 14..<16)
    let second = decimal(bytes, in: 17..<19)
    guard year > 0,
      (1...12).contains(month),
      (1...daysInMonth(year: year, month: month)).contains(day),
      (0...23).contains(hour),
      (0...59).contains(minute),
      (0...59).contains(second)
    else {
      return nil
    }

    var nanosecond = 0
    var timezoneStart = 19
    if bytes[timezoneStart] == 46 {
      let fractionStart = timezoneStart + 1
      var fractionEnd = fractionStart
      while fractionEnd < bytes.count, bytes[fractionEnd] >= 48, bytes[fractionEnd] <= 57 {
        fractionEnd += 1
      }
      // The handoff contract caps fractional precision at nanoseconds.
      guard fractionEnd > fractionStart,
        fractionEnd - fractionStart <= 9
      else {
        return nil
      }
      let fraction = decimal(bytes, in: fractionStart..<fractionEnd)
      nanosecond = fraction * powerOfTen(9 - (fractionEnd - fractionStart))
      timezoneStart = fractionEnd
    }

    guard timezoneStart < bytes.count else { return nil }
    var offsetSeconds = 0
    if bytes[timezoneStart] == 90 {
      guard timezoneStart + 1 == bytes.count else { return nil }
    } else if bytes[timezoneStart] == 43 || bytes[timezoneStart] == 45 {
      guard timezoneStart + 6 == bytes.count,
        bytes[timezoneStart + 3] == 58,
        isDigits(bytes, in: (timezoneStart + 1)..<(timezoneStart + 3)),
        isDigits(bytes, in: (timezoneStart + 4)..<(timezoneStart + 6))
      else {
        return nil
      }
      let offsetHour = decimal(bytes, in: (timezoneStart + 1)..<(timezoneStart + 3))
      let offsetMinute = decimal(bytes, in: (timezoneStart + 4)..<(timezoneStart + 6))
      guard (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else {
        return nil
      }
      let magnitude = offsetHour * 3_600 + offsetMinute * 60
      offsetSeconds = bytes[timezoneStart] == 45 ? -magnitude : magnitude
    } else {
      return nil
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    components.nanosecond = nanosecond
    guard let localDate = calendar.date(from: components) else { return nil }
    return localDate.addingTimeInterval(TimeInterval(-offsetSeconds))
  }

  private static func isDigits(_ bytes: [UInt8], in range: Range<Int>) -> Bool {
    range.allSatisfy { index in
      index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57
    }
  }

  private static func decimal(_ bytes: [UInt8], in range: Range<Int>) -> Int {
    range.reduce(into: 0) { value, index in
      value = value * 10 + Int(bytes[index] - 48)
    }
  }

  private static func powerOfTen(_ exponent: Int) -> Int {
    (0..<exponent).reduce(into: 1) { value, _ in value *= 10 }
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2:
      let leapYear = year.isMultiple(of: 400)
        || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
      return leapYear ? 29 : 28
    case 4, 6, 9, 11:
      return 30
    default:
      return 31
    }
  }
}
