# Third-party notices

`sim-ax-settings.m.txt` is adapted from
[`EvanBacon/serve-sim`](https://github.com/EvanBacon/serve-sim) at commit
`af681b8c3b0453f31dcb8e98a3389f23b7cfc6b0`.

Copyright 2026 Evan Bacon. Licensed under Apache License 2.0. The complete
license is bundled at `../CameraInjector/LICENSE-serve-sim`.

cmux changed the build orchestration so the source is compiled on demand in
the isolated worker, cached by source and active Simulator SDK, and invoked
only through argv-based `simctl spawn` commands.
