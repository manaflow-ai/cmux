#!/usr/bin/env node
"use strict";

// Placeholder distribution. The working multiplexer is a Rust binary; a future
// release will download or bundle it. See https://github.com/manaflow-ai/acpmux
const { version } = require("../package.json");

process.stderr.write(
  `acpmux ${version} (placeholder distribution)\n\n` +
    "This npm package does not contain the multiplexer yet. acpmux is a Rust\n" +
    "daemon; build it from source:\n\n" +
    "    git clone https://github.com/manaflow-ai/acpmux\n" +
    "    cd acpmux\n" +
    "    cargo build --release\n\n" +
    "A future release of this package will ship the compiled binary.\n",
);
process.exit(1);
