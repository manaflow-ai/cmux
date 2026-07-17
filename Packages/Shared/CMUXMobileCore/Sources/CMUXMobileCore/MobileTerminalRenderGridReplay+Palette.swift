import Foundation

extension MobileTerminalRenderGridReplay {
    func appendPaletteRestore(to bytes: inout Data) {
        guard let effectivePalette = frame.terminalTheme?.palette else { return }
        guard effectivePalette.count == TerminalTheme.paletteCount
            || effectivePalette.count == TerminalTheme.extendedPaletteCount else { return }
        bytes.reserveCapacity(bytes.count + effectivePalette.count * 28)
        appendPaletteReset(count: effectivePalette.count, to: &bytes)
        let configPalette = frame.terminalConfigTheme?.palette
        for (index, color) in effectivePalette.enumerated() {
            guard let rgb = TerminalTheme.rgbComponents(color) else { continue }
            if let configPalette,
               configPalette.indices.contains(index),
               let configRGB = TerminalTheme.rgbComponents(configPalette[index]),
               configRGB.red == rgb.red,
               configRGB.green == rgb.green,
               configRGB.blue == rgb.blue { continue }
            appendPaletteOverride(index: index, rgb: rgb, to: &bytes)
        }
    }

    private func appendPaletteReset(count: Int, to bytes: inout Data) {
        bytes.append(contentsOf: [0x1B, 0x5D, 0x31, 0x30, 0x34])
        if count < TerminalTheme.extendedPaletteCount {
            for index in 0..<count {
                bytes.append(0x3B)
                appendDecimal(index, to: &bytes)
            }
        }
        bytes.append(contentsOf: [0x1B, 0x5C])
    }

    private func appendPaletteOverride(
        index: Int,
        rgb: (red: Int, green: Int, blue: Int),
        to bytes: inout Data
    ) {
        bytes.append(contentsOf: [0x1B, 0x5D, 0x34, 0x3B])
        appendDecimal(index, to: &bytes)
        bytes.append(contentsOf: [0x3B, 0x72, 0x67, 0x62, 0x3A])
        appendHexByte(rgb.red, to: &bytes)
        bytes.append(0x2F)
        appendHexByte(rgb.green, to: &bytes)
        bytes.append(0x2F)
        appendHexByte(rgb.blue, to: &bytes)
        bytes.append(contentsOf: [0x1B, 0x5C])
    }

    private func appendDecimal(_ value: Int, to bytes: inout Data) {
        if value >= 100 { bytes.append(UInt8(value / 100) + 0x30) }
        if value >= 10 { bytes.append(UInt8((value / 10) % 10) + 0x30) }
        bytes.append(UInt8(value % 10) + 0x30)
    }

    private func appendHexByte(_ value: Int, to bytes: inout Data) {
        bytes.append(hexDigit((value >> 4) & 0x0F))
        bytes.append(hexDigit(value & 0x0F))
    }

    private func hexDigit(_ value: Int) -> UInt8 {
        value < 10 ? UInt8(value) + 0x30 : UInt8(value - 10) + 0x61
    }
}
