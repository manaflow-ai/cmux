import AppKit
import CmuxSidebar
import Foundation
import SwiftUI

@MainActor
func run() {
    var outputPath = NSString(string: "~/Developer/lab/cmux-rail/.gallery").expandingTildeInPath
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let flag = arguments.first {
        arguments.removeFirst()
        if flag == "--output", let value = arguments.first {
            outputPath = value
            arguments.removeFirst()
        }
    }

    let renderer = GalleryRenderer(
        outputDirectory: URL(fileURLWithPath: outputPath),
        scale: 2
    )
    do {
        try renderer.render(GalleryCatalog.scenes())
        print("gallery written to \(outputPath)")
    } catch {
        print("gallery failed: \(error)")
        exit(1)
    }
}

run()
