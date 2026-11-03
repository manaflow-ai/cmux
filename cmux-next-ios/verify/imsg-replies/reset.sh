#!/bin/bash
# Fresh paired state: both gesture servers, both apps reseeded, keyboards down.
OUT=${OUT:-$HOME/imsgreply/out/light}; source ~/imsgreply/pair.sh
export DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer
if ! { _galive ref && _galive ours; }; then
  serve_start
  until grep -q "testServe\]' started" $GDIR/ref.log && grep -q "testServe\]' started" $GDIR/ours.log; do sleep 1; done
  sleep 2
fi
bash ~/imsgreply/oursseed.sh
bash ~/imsgreply/refseed.sh
g ours drag 220 400 220 900 0.02 1500 0; sleep 1
