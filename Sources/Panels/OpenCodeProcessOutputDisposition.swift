import Foundation

enum OpenCodeProcessOutputDisposition: Equatable {
    case emit
    case suppress
    case serverURL(URL)
}
