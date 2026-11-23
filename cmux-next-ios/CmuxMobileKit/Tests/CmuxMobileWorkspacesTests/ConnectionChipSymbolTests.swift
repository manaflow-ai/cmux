#if os(iOS)
@testable import CmuxMobileBrowserStream
import CmuxMobileDesign
@testable import CmuxMobileWorkspaces
import Testing

/// One state, one symbol on every surface: a chip that says "Mac offline" draws the same symbol
/// on the Home list, the Workspaces banner, the browser and the terminal, and no two states share
/// a symbol. "Offline" (the phone has no network) keeps wifi-slash.
@MainActor struct ConnectionChipSymbolTests {
    /// Every chip any surface builds, by where it comes from.
    static var everyChip: [(String, ConnectionChip.Content)] {
        var chips: [(String, ConnectionChip.Content)] = []
        let banners: [(String, ConnectionBannerState)] = [
            ("banner reconnecting", .reconnecting(to: "Mac Studio")),
            ("banner connecting", .connecting(to: "Mac Studio")),
            ("banner offline", .offline),
            ("banner mac offline", .macOffline("Mac Studio")),
            ("banner connection failed", .connectionFailed),
        ]
        for (name, state) in banners {
            if let chip = state.chip { chips.append((name, chip)) } else { Issue.record("\(name): no chip") }
        }
        for state in ListStatusRow.State.allCases { chips.append(("list \(state)", state.chip)) }
        for reason in [StreamedBrowserModel.reconnectingText, StreamedBrowserModel.linkReconnectingText] {
            if let chip = StreamedBrowserModel.linkChip(for: reason) { chips.append(("browser \(reason)", chip)) }
        }
        return chips
    }

    @Test func eachStateHasOneSymbolOnEverySurface() {
        var symbolsByWord: [String: Set<String>] = [:]
        var wordsBySymbol: [String: Set<String>] = [:]
        for (_, chip) in Self.everyChip {
            let symbol = chip.symbol ?? "spinner"
            symbolsByWord[chip.word, default: []].insert(symbol)
            if chip.symbol != nil { wordsBySymbol[symbol, default: []].insert(chip.word) }
        }
        for (word, symbols) in symbolsByWord {
            #expect(symbols.count == 1, "\(word) draws \(symbols.sorted()) across surfaces")
        }
        for (symbol, words) in wordsBySymbol {
            #expect(words.count == 1, "\(symbol) means \(words.sorted())")
        }
        #expect(symbolsByWord["Offline"] == ["wifi.slash"])
        #expect(symbolsByWord["Mac offline"] == ["moon.zzz"])
    }

    /// The map itself: no two kinds share words or a symbol.
    @Test func kindsAreDistinct() {
        let kinds = ConnectionChip.Kind.allCases
        #expect(Set(kinds.map(\.word)).count == kinds.count)
        let symbols = kinds.compactMap(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }
}
#endif
