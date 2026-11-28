#!/bin/bash
set -o pipefail
export CMUX_BROWSER_TESTS=1
bash scripts/ci/run-webviews-tests.sh \
  webviews/test/browser/golden-look-contrast-0.test.ts webviews/test/browser/golden-look-contrast-1.test.ts \
  webviews/test/browser/golden-look-contrast-2.test.ts webviews/test/browser/golden-look-contrast-3.test.ts \
  webviews/test/control-contrast-7.test.ts webviews/test/control-contrast-9.test.ts webviews/test/control-contrast-10.test.ts \
  webviews/test/accent-glass-invariants-7.test.ts webviews/test/browser/gallery-control-surfaces-1.test.ts \
  webviews/test/browser/gallery-control-surfaces-3.test.ts webviews/test/browser/look-addons.test.ts \
  webviews/test/feel-thought-row.test.ts webviews/test/feel-tray.test.ts \
  webviews/test/guest-page-first-frame-browser.test.ts webviews/test/hat-composer-icon-grid.test.ts 2>&1 | grep -v '^\s*at '
