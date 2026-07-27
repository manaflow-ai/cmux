# Third-party notices

## serve-sim

Repository: https://github.com/EvanBacon/serve-sim

Commit: `af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0`

License: Apache License 2.0. The full text is bundled as
`LICENSE-serve-sim` in this directory.

The Objective-C camera injector files are adapted copies, with `.txt` appended
to implementation filenames for SwiftPM resource packaging. cmux extends the
shared camera wire format with per-process attachment slots and lifecycle
heartbeats so the worker can report liveness and reinject exited targets. The
worker's framebuffer callback ABI, HID transport, accessibility bridge, and
TCC/BulletinBoard permission behavior are adapted implementations. The
accessibility bridge is modified to return typed, capped snapshots and to
spread bounded hit-test discovery across the full simulated display.

## Baguette

Repository: https://github.com/tddworks/baguette

Commit: `41275800a597ef6d3bfbad27a9fbcc0861c62c2d`

License: Apache License 2.0. The same full Apache License 2.0 text is bundled
as `LICENSE-serve-sim`.

Copyright 2026 tddworks.

The CoreSimulator device lookup, framebuffer descriptor selection, Indigo HID
fallback behavior, and PurpleWorkspacePort rotation transport are adapted
implementations. No Baguette source file is copied verbatim.

## OpenStreetMap

The five built-in location routes retain latitude and longitude samples that
serve-sim derived from OpenStreetMap. Sources include Apple Park way 518104809,
Golden Gate Bridge ways 537838948 and 595194543, the Steep Ravine and Matt
Davis trails, Central Park way 179679714, and CA 1 ways through Pacifica.

Map data © OpenStreetMap contributors and available under the Open Data
Commons Open Database License (ODbL): https://www.openstreetmap.org/copyright

## idb

Repository: https://github.com/facebook/idb

Commit: `8690e8cdd1885bcab6c50a350330799ff792405f`

License: MIT.

The Xcode 27 DTUHID XPC envelope, service lookup, event models, button usages,
accessibility translator bridge, and rotation wire format are adapted
implementations. No idb source file is copied verbatim.

Copyright (c) Meta Platforms, Inc. and affiliates.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## React Native

Repository: https://github.com/facebook/react-native

Commit: `102fde7b6bf699dac9769b5336d9bbde2e228109`

License: MIT.

`RCTReloadCommand` was used only as a behavioral reference to confirm that
development builds register Command-R as their reload key command. No React
Native source code is copied or adapted.
