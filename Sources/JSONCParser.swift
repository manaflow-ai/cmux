import Foundation

enum JSONCParser {
    static func preprocess(data: Data) throws -> Data {
        guard let source = String(data: data, encoding: .utf8) else {
            throw JSONCError.invalidUTF8
        }
        let withoutBOM = source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source
        let stripped = try stripComments(from: withoutBOM)
        let normalized = stripTrailingCommas(from: stripped)
        return Data(normalized.utf8)
    }

    private static func stripComments(from source: String) throws -> String {
        var result = ""
        var index = source.startIndex
        var inString = false
        var isEscaped = false

        while index < source.endIndex {
            let character = source[index]

            if inString {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "/" {
                let nextIndex = source.index(after: index)
                if nextIndex < source.endIndex {
                    let next = source[nextIndex]
                    if next == "/" {
                        index = source.index(after: nextIndex)
                        while index < source.endIndex && source[index] != "\n" {
                            index = source.index(after: index)
                        }
                        continue
                    }
                    if next == "*" {
                        index = source.index(after: nextIndex)
                        var didClose = false
                        while index < source.endIndex {
                            let current = source[index]
                            let followingIndex = source.index(after: index)
                            if current == "*" && followingIndex < source.endIndex && source[followingIndex] == "/" {
                                index = source.index(after: followingIndex)
                                didClose = true
                                break
                            }
                            index = followingIndex
                        }
                        guard didClose else {
                            throw JSONCError.unterminatedBlockComment
                        }
                        continue
                    }
                }
            }

            result.append(character)
            index = source.index(after: index)
        }

        return result
    }

    private static func stripTrailingCommas(from source: String) -> String {
        var result = ""
        var index = source.startIndex
        var inString = false
        var isEscaped = false

        while index < source.endIndex {
            let character = source[index]

            if inString {
                result.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = source.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = source.index(after: index)
                continue
            }

            if character == "," {
                var lookahead = source.index(after: index)
                while lookahead < source.endIndex && source[lookahead].isWhitespace {
                    lookahead = source.index(after: lookahead)
                }
                if lookahead < source.endIndex && (source[lookahead] == "}" || source[lookahead] == "]") {
                    index = source.index(after: index)
                    continue
                }
            }

            result.append(character)
            index = source.index(after: index)
        }

        return result
    }

    private enum JSONCError: Error {
        case invalidUTF8
        case unterminatedBlockComment
    }
}
