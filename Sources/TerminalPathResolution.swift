import Foundation
import CmuxTerminalCopyMode
import CmuxSocketControl
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import os
import Sentry
import Bonsplit
import CMUXAgentLaunch
import CMUXMobileCore
import CMUXPasteboardFidelity
import IOSurface
import UniformTypeIdentifiers


// MARK: - Terminal path and open-URL resolution
func cmuxResolveQuicklookPath(
    _ rawText: String,
    cwd: String?,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String? {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var seenPaths: Set<String> = []
    for token in cmuxQuicklookPathCandidates(from: trimmed) {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { continue }

        let expandedToken = (normalizedToken as NSString).expandingTildeInPath
        let candidatePath: String
        if expandedToken.hasPrefix("/") {
            candidatePath = expandedToken
        } else {
            guard let cwd, !cwd.isEmpty else { continue }
            candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
        }

        let standardizedPath = (candidatePath as NSString).standardizingPath
        guard seenPaths.insert(standardizedPath).inserted else { continue }
        if fileExists(standardizedPath) {
            return standardizedPath
        }
    }

    return nil
}

private func cmuxQuicklookPathCandidates(from rawText: String) -> [String] {
    var candidates: [String] = []

    func append(_ candidate: String?) {
        guard let candidate else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        func appendUnique(_ value: String) {
            guard !value.isEmpty, !candidates.contains(value) else { return }
            candidates.append(value)
        }

        appendUnique(trimmed)
        let punctuationTrimmed = cmuxTrimTerminalPathTrailingPunctuation(trimmed)
        if punctuationTrimmed != trimmed {
            appendUnique(punctuationTrimmed)
        }
    }

    append(rawText)

    let unescaped = cmuxUnescapeShellToken(rawText)
    if unescaped != rawText {
        append(unescaped)
    }

    if let unquoted = cmuxUnquoteShellToken(rawText) {
        append(unquoted)
        let unescapedUnquoted = cmuxUnescapeShellToken(unquoted)
        if unescapedUnquoted != unquoted {
            append(unescapedUnquoted)
        }
    }

    return candidates
}

private let cmuxTerminalPathSentencePunctuation: Set<Character> = [
    ".", ",", ";", ":", "!", "?"
]

private let cmuxTerminalPathTrailingQuotes: Set<Character> = [
    "\"", "'", "”", "’", "»"
]

private let cmuxTerminalPathClosingPairs: [Character: Character] = [
    ")": "(",
    "]": "[",
    "}": "{",
    ">": "<"
]

/// Mirror smart-link terminals by trimming only the trailing punctuation run
/// that is clearly outside the path itself.
func cmuxTrimTerminalPathTrailingPunctuation(_ token: String) -> String {
    let characters = Array(token)
    guard !characters.isEmpty else { return token }

    var end = characters.count
    while end > 0 {
        let trailing = characters[end - 1]
        if cmuxTerminalPathSentencePunctuation.contains(trailing) ||
            cmuxTerminalPathTrailingQuotes.contains(trailing) {
            end -= 1
            continue
        }

        if let opener = cmuxTerminalPathClosingPairs[trailing],
           !cmuxHasUnmatchedOpeningPathDelimiter(
               in: characters[..<(end - 1)],
               opener: opener,
               closer: trailing
           ) {
            end -= 1
            continue
        }

        break
    }

    guard end < characters.count else { return token }
    return String(characters[..<end])
}

private func cmuxHasUnmatchedOpeningPathDelimiter(
    in characters: ArraySlice<Character>,
    opener: Character,
    closer: Character
) -> Bool {
    var balance = 0
    for character in characters {
        if character == opener {
            balance += 1
        } else if character == closer, balance > 0 {
            balance -= 1
        }
    }
    return balance > 0
}

private func cmuxUnquoteShellToken(_ token: String) -> String? {
    guard token.count >= 2,
          let first = token.first,
          let last = token.last,
          first == last,
          first == "'" || first == "\"" else {
        return nil
    }
    return String(token.dropFirst().dropLast())
}

private func cmuxUnescapeShellToken(_ token: String) -> String {
    var output = String.UnicodeScalarView()
    output.reserveCapacity(token.unicodeScalars.count)
    var escaping = false

    for scalar in token.unicodeScalars {
        if escaping {
            output.append(scalar)
            escaping = false
            continue
        }

        if scalar == "\\" {
            escaping = true
            continue
        }

        output.append(scalar)
    }

    if escaping {
        output.append(UnicodeScalar(0x5C)!)
    }

    return String(output)
}

func cmuxVisibleTerminalLines(from text: String, rows: Int) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.count > rows {
        return Array(lines.suffix(rows))
    }
    return lines
}

private func cmuxShellEscapedTokenContainingColumn(
    in line: String,
    column: Int
) -> String? {
    let characters = Array(line)
    guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }

    var index = 0
    while index < characters.count {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        let start = index

        while index < characters.count {
            let character = characters[index]
            guard character.isWhitespace else {
                index += 1
                continue
            }

            var backslashCount = 0
            var lookbehind = index - 1
            while lookbehind >= start, characters[lookbehind] == "\\" {
                backslashCount += 1
                lookbehind -= 1
            }

            if backslashCount % 2 == 1 {
                index += 1
                continue
            }

            break
        }

        if start < index, column >= start, column < index {
            return String(characters[start..<index])
        }
    }

    return nil
}

private func cmuxIsHardPathDelimiter(
    in characters: [Character],
    at index: Int
) -> Bool {
    let character = characters[index]
    if character == "\t" || character == "\n" || character == "\r" {
        return true
    }

    guard character.isWhitespace else { return false }
    let previousIsWhitespace = index > 0 && characters[index - 1].isWhitespace
    let nextIsWhitespace = (index + 1) < characters.count && characters[index + 1].isWhitespace
    return previousIsWhitespace || nextIsWhitespace
}

private func cmuxRawPathSegmentContainingColumn(
    in line: String,
    column: Int
) -> String? {
    let characters = Array(line)
    guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }
    guard !cmuxIsHardPathDelimiter(in: characters, at: column) else { return nil }

    var start = column
    while start > 0, !cmuxIsHardPathDelimiter(in: characters, at: start - 1) {
        start -= 1
    }

    var end = column
    while (end + 1) < characters.count, !cmuxIsHardPathDelimiter(in: characters, at: end + 1) {
        end += 1
    }

    let candidate = String(characters[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    return candidate.isEmpty ? nil : candidate
}

private func cmuxPathCandidatesContainingColumn(
    in line: String,
    column: Int
) -> [String] {
    var candidates: [String] = []

    func append(_ candidate: String?) {
        guard let candidate else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
        candidates.append(trimmed)
    }

    append(cmuxRawPathSegmentContainingColumn(in: line, column: column))
    append(cmuxShellEscapedTokenContainingColumn(in: line, column: column))

    return candidates
}

func cmuxResolveVisibleLinePath(
    _ line: String,
    column: Int,
    cwd: String,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> (rawToken: String, path: String)? {
    for rawToken in cmuxPathCandidatesContainingColumn(in: line, column: column) {
        if let resolvedPath = cmuxResolveQuicklookPath(rawToken, cwd: cwd, fileExists: fileExists) {
            return (rawToken, resolvedPath)
        }
    }
    return nil
}

func cmuxResolveTerminalOpenURLFilePath(
    _ rawText: String,
    cwd: String?,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String? {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard URL(string: trimmed)?.scheme == nil else { return nil }
    return cmuxResolveQuicklookPath(trimmed, cwd: cwd, fileExists: fileExists)
}

enum TerminalOpenURLTarget: Equatable {
    case embeddedBrowser(URL)
    case external(URL)

    var url: URL {
        switch self {
        case let .embeddedBrowser(url), let .external(url):
            return url
        }
    }
}

func resolveTerminalOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    #if DEBUG
    cmuxDebugLog("link.resolve input=\(trimmed)")
    #endif
    guard !trimmed.isEmpty else {
        #if DEBUG
        cmuxDebugLog("link.resolve result=nil (empty)")
        #endif
        return nil
    }

    if NSString(string: trimmed).isAbsolutePath {
        #if DEBUG
        cmuxDebugLog("link.resolve result=external(absolutePath) url=\(trimmed)")
        #endif
        return .external(URL(fileURLWithPath: trimmed))
    }

    if let parsed = URL(string: trimmed),
       let scheme = parsed.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            guard BrowserInsecureHTTPSettings.normalizeHost(parsed.host ?? "") != nil else {
                #if DEBUG
                cmuxDebugLog("link.resolve result=external(invalidHost) url=\(parsed)")
                #endif
                return .external(parsed)
            }
            #if DEBUG
            cmuxDebugLog("link.resolve result=embeddedBrowser url=\(parsed)")
            #endif
            return .embeddedBrowser(parsed)
        }
        #if DEBUG
        cmuxDebugLog("link.resolve result=external(scheme=\(scheme)) url=\(parsed)")
        #endif
        return .external(parsed)
    }

    if let webURL = resolveBrowserNavigableURL(trimmed) {
        guard BrowserInsecureHTTPSettings.normalizeHost(webURL.host ?? "") != nil else {
            #if DEBUG
            cmuxDebugLog("link.resolve result=external(bareHost-invalidHost) url=\(webURL)")
            #endif
            return .external(webURL)
        }
        #if DEBUG
        cmuxDebugLog("link.resolve result=embeddedBrowser(bareHost) url=\(webURL)")
        #endif
        return .embeddedBrowser(webURL)
    }

    guard let fallback = URL(string: trimmed) else {
        #if DEBUG
        cmuxDebugLog("link.resolve result=nil (unparseable)")
        #endif
        return nil
    }
    #if DEBUG
    cmuxDebugLog("link.resolve result=external(fallback) url=\(fallback)")
    #endif
    return .external(fallback)
}

