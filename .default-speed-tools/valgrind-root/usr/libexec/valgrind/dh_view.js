
//--------------------------------------------------------------------*/
//--- DHAT: a Dynamic Heap Analysis Tool                dh_view.js ---*/
//--------------------------------------------------------------------*/

/*
   This file is part of DHAT, a Valgrind tool for profiling the
   heap usage of programs.

   Copyright (C) 2018 Mozilla Foundation

   This program is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License as
   published by the Free Software Foundation; either version 2 of the
   License, or (at your option) any later version.

   This program is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.

   The GNU General Public License is contained in the file COPYING.
*/

/*
   Parts of this file are derived from Firefox, copyright Mozilla Foundation,
   and may be redistributed under the terms of the Mozilla Public License
   Version 2.0, as well as under the license of this project.  A copy of the
   Mozilla Public License Version 2.0 is available at at
   https://www.mozilla.org/en-US/MPL/2.0/.
*/

// Test this file by loading dh_view.html?test=1. That runs the tests in
// dh_test.js and gives pass/fail indicators.

"use strict";

//------------------------------------------------------------//
//--- Globals                                              ---//
//------------------------------------------------------------//

// Important HTML elements.
let gInput;
let gSelect;
let gHeaderDiv, gTestingDiv, gMainDiv, gLegendDiv, gTimingsDiv;

// The name of the loaded file.
let gFilename;

// The object extracted from the JSON input.
let gData = {};

// The root of the radix tree build from gData. A radix tree is a
// space-optimized prefix tree in which each node that is the only child is
// merged with its parent.
let gRoot;

// Data relating to the sort metrics.
//
// - isDefault: True for the default sort metric.
// - label: Used in the drop-down menu.
// - bolds: Which fields to highlight in the output.
// - cmpField: Field used to sort the radix tree.
// - enable: Function saying whether this option is enabled.
// - sig: Significance function used to determine aggregate nodes.
// - sigLabel: Significance threshold description function.
//
const gSelectData = [
  {
    label: () => `Total (${bytesUnit()})`,
    bolds: { "totalTitle": 1, "totalBytes": 1 },
    cmpField: "_totalBytes",
    enable: (aBkLt, aBkAcc) => true,
    sig: (aT) => aT._totalBytes >= 0.01 * gRoot._totalBytes,
    sigLabel: () => `\
total >= ${bytesAndPerc(0.01 * gRoot._totalBytes, gRoot._totalBytes)}`
  },
  {
    isDefault: true,
    label: () => `Total (${blocksUnit()})`,
    bolds: { "totalTitle": 1, "totalBlocks": 1 },
    cmpField: "_totalBlocks",
    enable: (aBkLt, aBkAcc) => true,
    sig: (aT) => aT._totalBlocks >= 0.01 * gRoot._totalBlocks,
    sigLabel: () => `\
total >= ${blocksAndPerc(0.01 * gRoot._totalBlocks, gRoot._totalBlocks)}`
  },
  // No "Total (bytes), tiny" because it's extremely unlikely that a PP with a
  // tiny average size will take up a significant number of bytes.
  {
    label: () => `Total (${blocksUnit()}), tiny`,
    bolds: { "totalTitle": 1, "totalBlocks": 1, "totalAvgSizeBytes": 1 },
    cmpField: "_totalBlocks",
    enable: (aBkLt, aBkAcc) => true,
    sig: (aT) => aT._totalBlocks >= 0.005 * gRoot._totalBlocks &&
                 aT._totalAvgSizeBytes() <= 16,
    sigLabel: () => `\
(total >= ${blocksAndPerc(0.005 * gRoot._totalBlocks, gRoot._totalBlocks)}) && \
(avg size <= ${bytes(16)})`
  },
  // No "Total (bytes), short-lived", because a PP with few large, short-lived
  // blocks is unlikely. (In contrast, "Total (blocks), short-lived" is useful,
  // because a PP with many small, short-lived blocks *is* likely.) And if
  // such a PP existed, it'll probably show up in "Total (bytes), zero reads
  // or zero writes" or "Total (bytes), low-access" anyway, because there's
  // little time for accesses in a small number of instructions.
  {
    label: () => "Total (blocks), short-lived",
    bolds: { "totalTitle": 1, "totalBlocks": 1, "totalAvgLifetime": 1 },
    cmpField: "_totalBlocks",
    enable: (aBkLt, aBkAcc) => aBkLt,
    sig: (aT) => aT._totalBlocks >= 0.005 * gRoot._totalBlocks &&
                 aT._totalAvgLifetimes() <= gData.tuth,
    sigLabel: () => `\
(total >= ${blocksAndPerc(0.005 * gRoot._totalBlocks, gRoot._totalBlocks)}) && \
(avg lifetime <= ${time(gData.tuth)})`
  },
  {
    label: () => "Total (bytes), zero reads or zero writes",
    bolds: { "totalTitle": 1, "totalBytes": 1,
             "readsTitle": 1, "readsBytes": 1,
             "writesTitle": 1, "writesBytes": 1,
           },
    cmpField: "_totalBytes",
    enable: (aBkLt, aBkAcc) => aBkAcc,
    sig: (aT) => aT._totalBytes >= 0.005 * gRoot._totalBytes &&
                 (aT._readsBytes === 0 || aT._writesBytes === 0),
    sigLabel: () => `\
(total >= ${bytesAndPerc(0.005 * gRoot._totalBytes, gRoot._totalBytes)}) && \
((reads == ${bytes(0)}) || (writes == ${bytes(0)}))`
  },
  {
    label: () => "Total (blocks), zero reads or zero writes",
    bolds: { "totalTitle": 1, "totalBlocks": 1,
             "readsTitle": 1, "readsBytes": 1,
             "writesTitle": 1, "writesBytes": 1,
           },
    cmpField: "_totalBlocks",
    enable: (aBkLt, aBkAcc) => aBkAcc,
    sig: (aT) => aT._totalBlocks >= 0.005 * gRoot._totalBlocks &&
                 (aT._readsBytes === 0 || aT._writesBytes === 0),
    sigLabel: () => `\
(total >= ${blocksAndPerc(0.005 * gRoot._totalBlocks, gRoot._totalBlocks)}) && \
((reads == ${bytes(0)}) || (writes == ${bytes(0)}))`
  },
  {
    label: () => "Total (bytes), low-access",
    bolds: { "totalTitle": 1, "totalBytes": 1,
             "readsTitle": 1, "readsAvgPerByte": 1,
             "writesTitle": 1, "writesAvgPerByte": 1,
           },
    cmpField: "_totalBytes",
    enable: (aBkLt, aBkAcc) => aBkAcc,
    sig: (aT) => aT._totalBytes >= 0.005 * gRoot._totalBytes &&
                 aT._readsBytes !== 0 &&
                 aT._writesBytes !== 0 &&
                 (aT._readsAvgPerByte() <= 0.4 ||
                  aT._writesAvgPerByte() <= 0.4),
    sigLabel: () => `\
(total >= ${bytesAndPerc(0.005 * gRoot._totalBytes, gRoot._totalBytes)}) && \
(reads != ${bytes(0)}) && \
(writes != ${bytes(0)}) && \
((reads <= ${perByte(0.4)}) || (writes <= ${perByte(0.4)}))`
  },
  {
    label: () => "Total (blocks), low-access",
    bolds: { "totalTitle": 1, "totalBlocks": 1,
             "readsTitle": 1, "readsAvgPerByte": 1,
             "writesTitle": 1, "writesAvgPerByte": 1,
           },
    cmpField: "_totalBlocks",
    enable: (aBkLt, aBkAcc) => aBkAcc,
    sig: (aT) => aT._totalBlocks >= 0.005 * gRoot._totalBlocks &&
                 aT._readsBytes !== 0 &&
                 aT._writesBytes !== 0 &&
                 (aT._readsAvgPerByte() <= 0.4 ||
                  aT._writesAvgPerByte() <= 0.4),
    sigLabel: () => `\
(total >= ${blocksAndPerc(0.005 * gRoot._totalBlocks, gRoot._totalBlocks)}) && \
(reads != ${bytes(0)}) && \
(writes != ${bytes(0)}) && \
((reads <= ${perByte(0.4)}) || (writes <= ${perByte(0.4)}))`
  },
  // No "Total (avg size bytes)": not interesting.
  // No "Total (avg lifetime)": covered by "Total (blocks), short-lived".
  // No "Max (bytes)": not interesting, and unclear how to sort.
  // No "Max (blocks)": not interesting, and unclear how to sort.
  // No "Max (avg size bytes)": not interesting, and unclear how to sort.
  {
    label: () => "At t-gmax (bytes)",
    bolds: { "atTGmaxTitle": 1, "atTGmaxBytes": 1 },
    cmpField: "_atTGmaxBytes",
    enable: (aBkLt, aBkAcc) => aBkLt,
    sig: (aT) => aT._atTGmaxBytes >= 0.01 * gRoot._atTGmaxBytes,
    sigLabel: () => `\
at-t-gmax >= ${bytesAndPerc(0.01 * gRoot._atTGmaxBytes, gRoot._atTGmaxBytes)}`
  },
  // No "At t-gmax (blocks)": not interesting.
  // No "At t-gmax (avg size bytes)": not interesting.
  {
    label: () => "At t-end (bytes)",
    bolds: { "atTEndTitle": 1, "atTEndBytes": 1 },
    cmpField: "_atTEndBytes",
    enable: (aBkLt, aBkAcc) => aBkLt,
    sig: (aT) => aT._atTEndBytes >= 0.01 * gRoot._atTEndBytes,
    sigLabel: () => `\
at-t-end >= ${bytesAndPerc(0.01 * gRoot._atTEndBytes, gRoot._atTEndBytes)}`
  },
  // No "At t-end (blocks)": not interesting.
  // No "At t-end (avg size bytes)": not interesting.
  {
    label: () => "Reads (bytes)",
    bolds: { "readsTitle": 1, "readsBytes": 1 },
    cmpField: "_readsBytes",
    enable: (aBkLt, aBkAcc) => aBkAcc,
    sig: (aT) => aT._readsBytes >= 0.01 * gRoot._readsBytes,
    sigLabel: () => `\
reads >= ${bytesAndPerc(0.01 * gRoot._readsBytes, gRoot._readsBytes)}`
  },
  {
    label: () => "Reads (bytes), high-access",
    bolds: { "readsTitle": 1, "readsBytes": 1, "readsAvgPerByte": 1 },
    cmpField: "_readsBytes",
    enable: (aBkLt, aBkAcc) => aBkAcc,
    sig: (aT) => aT._readsBytes >= 0.005 * gRoot._readsBytes &&
                 (aT._readsAvgPerByte() >= 1000 ||
                  aT._writesAvgPerByte() >= 1000),
    sigLabel: () => `\
(reads >= ${bytesAndPerc(0.005 * gRoot._readsBytes, gRoot._readsBytes)}) && \
((reads >= ${perByte(1000)}) || (writes >= ${perByte(1000)}))`
  },
  // No "Reads (avg per byte)": covered by other access-related ones.
  {
    label: () => "Writes (bytes)",
    bolds: { "writesTitle": 1, "writesBytes": 1 },
    cmpField: "_writesBytes",
    enable: (aBkLt, aBkAcc) => aBkAcc,
    sig: (aT) => aT._writesBytes >= 0.01 * gRoot._writesBytes,
    sigLabel: () => `\
writes >= ${bytesAndPerc(0.01 * gRoot._writesBytes, gRoot._writesBytes)}`
  },
  {
    label: () => "Writes (bytes), high-access",
    bolds: { "writesTitle": 1, "writesBytes": 1, "writesAvgPerByte": 1 },
    cmpField: "_writesBytes",
    enable: (aBkLt, aBkAcc) => aBkAcc,
    sig: (aT) => aT._writesBytes >= 0.005 * gRoot._writesBytes &&
                 (aT._readsAvgPerByte() >= 1000 ||
                  aT._writesAvgPerByte() >= 1000),
    sigLabel: () => `\
(writes >= ${bytesAndPerc(0.005 * gRoot._writesBytes, gRoot._writesBytes)}) && \
((reads >= ${perByte(1000)}) || (writes >= ${perByte(1000)}))`
  }
  // No "Writes (avg per byte)": covered by other access-related ones.
];

//------------------------------------------------------------//
//--- Utilities                                            ---//
//------------------------------------------------------------//

// Assertion. Fails if aMsg is missing.
function assert(aCond, aMsg) {
  if (!aCond || !aMsg) {
    throw new Error(`assertion failed: ${aMsg}`);
  }
}

// Division function that returns 0 instead of NaN for 0/0, which is what we
// always want.
function div(aNum, aDenom) {
  return aNum === 0 && aDenom === 0 ? 0 : aNum / aDenom;
}

// Execute a function, printing any exception to the page.
function tryFunc(aFunc) {
  try {
    aFunc();
  } catch (ex) {
    // Clear gRoot, so that any old or partially-built new value doesn't hang
    // around if after this exception is thrown.
    gRoot = undefined;
    clearMainDivWithText(ex.toString(), "error");
    throw ex;
  }
}

// Put some text in a div at the bottom of the page. Useful for debugging.
function debug(x) {
  let section = appendElement(document.body, "div", "section");
  appendElementWithText(section, "div", JSON.stringify(x), "debug noselect");
}

//------------------------------------------------------------//
//--- Radix tree building                                  ---//
//------------------------------------------------------------//

// Notes about the TreeNode kinds:
//
// --------------------------------------------------------------------
//                              Leaf          Internal        Aggregate
// --------------------------------------------------------------------
// Has this._kids?              No            Yes             No
// Has this._max*?              Yes           No              No
// Has this._accesses?          Maybe         Maybe           No
// Allowed this._sig values?    Self,None     Self,Desc,None  None
// How many this._add() calls?  1             1+              1+
// --------------------------------------------------------------------
//
const kLeaf     = 1;
const kInternal = 2;
const kAgg      = 3;

function TreeNode(aKind, aFrames) {
  this._kind = aKind;

  this._totalBytes = 0;
  this._totalBlocks = 0;

  this._totalLifetimes = 0;

  // These numbers only make sense for leaf nodes. Unlike total stats, which
  // can be summed, _maxBytes/_maxBlocks for two PPs can't be easily combined
  // because the maxes may have occurred at different times.
  if (this._kind === kLeaf) {
    this._maxBytes = 0;
    this._maxBlocks = 0;
  }

  this._atTGmaxBytes = 0;
  this._atTGmaxBlocks = 0;

  this._atTEndBytes = 0;
  this._atTEndBlocks = 0;

  this._readsBytes = 0;
  this._writesBytes = 0;

  // this._accesses is left undefined. It will be added if necessary.
  // The possible values have the following meanings:
  // - undefined means "unset accesses" (i.e. new node, never been set)
  // - length==0 means "no accesses" (i.e. some kids have accesses and some
  //   don't, or all kids have accesses but in different sizes)
  // - length>0 means "accesses" (i.e. all kids have accesses and all the same
  //   size)

  // If a node would only have a single child, we instead effectively inline it
  // in the parent. Therefore a node can have multiple frames.
  this._frames = aFrames;

  // this._kids is left undefined. It will be added if necessary.

  // this._sig is added later, by sigTree().
}

TreeNode.prototype = {
  _add(aTotalBytes, aTotalBlocks, aTotalLifetimes, aMaxBytes,
       aMaxBlocks, aAtTGmaxBytes, aAtTGmaxBlocks, aAtTEndBytes,
       aAtTEndBlocks, aReadsBytes, aWritesBytes, aAccesses) {

    // We ignore this._kind, this._frames, and this._kids.

    // Note: if !gData.bklt and/or !gData.bkacc, some of these fields these
    // values come from will be missing in the input file, so the values will
    // be `undefined`, and the fields will end up as `NaN`. But this is ok
    // because we don't show them.

    this._totalBytes += aTotalBytes;
    this._totalBlocks += aTotalBlocks;
    this._totalLifetimes += aTotalLifetimes;

    if (this._kind === kLeaf) {
      // Leaf nodes should only be added to once, because DHAT currently
      // produces records with unique locations. If we remove addresses from
      // frames in the future then something must be done here to sum non-zero
      // _maxBytes and _maxBlocks values, but it's unclear exactly what. Range
      // arithmetic is a (complicated) possibility.
      assert(this._maxBytes === 0, "bad _maxBytes: " + this._maxBytes);
      assert(this._maxBlocks === 0, "bad _maxBlocks: " + this._maxBlocks);
      this._maxBytes += aMaxBytes;
      this._maxBlocks += aMaxBlocks;
    }

    this._atTGmaxBytes += aAtTGmaxBytes;
    this._atTGmaxBlocks += aAtTGmaxBlocks;

    this._atTEndBytes += aAtTEndBytes;
    this._atTEndBlocks += aAtTEndBlocks;

    this._readsBytes += aReadsBytes;
    this._writesBytes += aWritesBytes;

    if (this._kind !== kAgg) {
      if (!this._accesses && aAccesses) {
        // unset accesses += accesses --> has accesses (must clone the array)
        this._accesses = aAccesses.slice();
      } else if (this._accesses && aAccesses &&
                 this._accesses.length === aAccesses.length) {
        // accesses += accesses (with matching lengths) --> accesses
        for (let i = 0; i < this._accesses.length; i++) {
          this._accesses[i] += aAccesses[i];
        }
      } else {
        // any other combination --> no accesses
        this._accesses = [];
      }
    } else {
      assert(!this._accesses, "agg nodes cannot have accesses");
    }
  },

  _addPP(aPP) {
    this._add(aPP.tb, aPP.tbk, aPP.tl, aPP.mb, aPP.mbk, aPP.gb, aPP.gbk,
              aPP.eb, aPP.ebk, aPP.rb, aPP.wb, aPP.acc);
  },

  // This is called in two cases.
  // - Splitting a node, where we are adding to a fresh node (i.e. effectively
  //   cloning a node).
  // - Aggregating multiple nodes.
  _addNode(aT) {
    this._add(aT._totalBytes, aT._totalBlocks, aT._totalLifetimes,
              aT._maxBytes, aT._maxBlocks, aT._atTGmaxBytes, aT._atTGmaxBlocks,
              aT._atTEndBytes, aT._atTEndBlocks,
              aT._readsBytes, aT._writesBytes, aT._accesses);
  },

  // Split the node after the aTi'th internal frame. The inheriting kid will
  // get the post-aTi frames; the new kid will get aNewFrames.
  _split(aTi, aPP, aNewFrames) {
    // kid1 inherits t's kind and values.
    let inheritedFrames = this._frames.splice(aTi + 1);
    let kid1 = new TreeNode(this._kind, inheritedFrames);
    if (this._kids) {
      kid1._kids = this._kids;
    }
    kid1._addNode(this);

    // Put all remaining frames into kid2.
    let kid2 = new TreeNode(kLeaf, aNewFrames);
    kid2._addPP(aPP);

    // Update this.
    if (this._kind === kLeaf) {
      // Convert to an internal node.
      this._kind = kInternal;
      assert(this.hasOwnProperty("_maxBytes"), "missing _maxBytes");
      assert(this.hasOwnProperty("_maxBlocks"), "missing _maxBlocks");
      delete this._maxBytes;
      delete this._maxBlocks;
    }
    this._kids = [kid1, kid2];
    this._addPP(aPP);
  },

  _totalAvgSizeBytes() {
    return div(this._totalBytes, this._totalBlocks);
  },

  _totalAvgLifetimes() {
    return div(this._totalLifetimes, this._totalBlocks);
  },

  _maxAvgSizeBytes() {
    assert(this._kind === kLeaf, "non-leaf node");
    return div(this._maxBytes, this._maxBlocks);
  },

  _atTGmaxAvgSizeBytes() {
    return div(this._atTGmaxBytes, this._atTGmaxBlocks);
  },

  _atTEndAvgSizeBytes() {
    return div(this._atTEndBytes, this._atTEndBlocks);
  },

  _readsAvgPerByte() {
    return div(this._readsBytes, this._totalBytes);
  },

  _writesAvgPerByte() {
    return div(this._writesBytes, this._totalBytes);
  }
}

// Check if the fields in `aFields` are present in `aObj`.
function checkFields(aObj, aFields) {
  for (let f of aFields) {
    if (!aObj.hasOwnProperty(f)) {
      throw new Error(`data file is missing a field: ${f}`);
    }
  }
}

// Do basic checking of a PP read from file.
function checkPP(aPP) {
  checkFields(aPP, ["tb", "tbk", "fs"]);
  if (gData.bklt) {
    checkFields(aPP, ["mb", "mbk", "gb", "gbk", "eb", "ebk"]);
  }
  if (gData.bkacc) {
    checkFields(aPP, ["rb", "wb"]);
  }
}

// Access counts latch as 0xffff. Treating 0xffff as Infinity gives us exactly
// the behaviour we want, e.g. Infinity + 1 = Infinity.
function normalizeAccess(aAcc) {
  if (aAcc < 0xffff) {
    return aAcc;
  }
  if (aAcc === 0xffff) {
    return Infinity;
  }
  assert(false, "too-large access value");
}

const kExpectedFileVersion = 2;

// Build gRoot from gData.
function buildTree() {
  // Check global values.
  let fields = ["dhatFileVersion", "mode", "verb",
                "bklt", "bkacc",
                "tu", "Mtu",
                "cmd", "pid",
                "te", "pps", "ftbl"];
  checkFields(gData, fields);
  if (gData.dhatFileVersion != kExpectedFileVersion) {
      throw new Error(
        `data file has version number ${gData.dhatFileVersion}, ` +
        `expected version number ${kExpectedFileVersion}`);
  }

  if (gData.bklt) {
    checkFields(gData, ["tg", "tuth"]);
  }

  // Update sort metric labels, and disable sort metrics that aren't allowed
  // for this data.
  for (let [i, option] of gSelect.childNodes.entries()) {
    let data = gSelectData[i];
    option.label = data.label();
    option.disabled = !data.enable(gData.bklt, gData.bkacc);
  }

  // If the selected sort metric was just disabled, switch the sort metric
  // back to the default (which is never disabled).
  let option = gSelect.childNodes[gSelect.selectedIndex];
  if (option.disabled) {
    for (let [i, data] of gSelectData.entries()) {
      let option = gSelect.childNodes[i];
      if (data.isDefault) {
        option.selected = true;
        break;
      }
    }
  }

  // Build the radix tree. Nodes are in no particular order to start with. The
  // algorithm is tricky because we need to use internal frames when possible.
  gRoot = new TreeNode(kLeaf, [0]);   // Frame 0 is always "[root]".

  for (let [i, pp] of gData.pps.entries()) {
    checkPP(pp);

    // Decompress the run-length encoding in `acc`, if present.
    if (pp.acc) {
      let acc = [];
      for (let i = 0; i < pp.acc.length; i++) {
        if (pp.acc[i] < 0) {
          // A negative number encodes a repeat count. The following entry has
          // the value to be repeated.
          let reps = -pp.acc[i++];
          let val = pp.acc[i];
          for (let j = 0; j < reps; j++) {
            acc.push(normalizeAccess(val));
          }
        } else {
          acc.push(normalizeAccess(pp.acc[i]));
        }
      }
      pp.acc = acc;
    }

    // The first PP is a special case, because we have to build gRoot.
    if (i === 0) {
      gRoot._frames.push(...pp.fs);
      gRoot._addPP(pp);
      continue;
    }

    let t = gRoot;  // current node
    let ti = 0;     // current frame index within t
    let done = false;

    // In the examples below, tree nodes have the form `abcd:N-Xs`, where
    // `abcd` is a frame sequence (and `-` is an empty sequence), `N` is a node
    // value, and `Xs` are the node's children.

    for (let [j, kidFrame] of pp.fs.entries()) {
      // Search for kidFrame among internal frames.
      if (ti + 1 < t._frames.length) {
        // t has an internal frame at the right index.

        if (t._frames[ti + 1] === kidFrame) {
          // The internal frame matches. Move to t's next internal frame.
          ti++;
        } else {
          // The internal frame doesn't match. Split the node.
          //
          // E.g. abcd:20-[] + abef:10 => ab:30-[cd:20-[], ef:10-[]]
          t._split(ti, pp, pp.fs.slice(j));
          done = true;
          break;
        }

      } else {
        // We've run out of internal frames in t. Consider t's kids.

        if (!t._kids) {
          // No kids; this must be a supersequence of an existing sequence.
          // Split t; the inheriting kid will get no frames, the new kid will
          // get the leftover frames.
          //
          // E.g. ab:20-[] + abcd:10 => ab:30-[-:20-[], cd:10-[]]
          t._split(ti, pp, pp.fs.slice(j));
          done = true;
          break;
        }

        t._addPP(pp);

        // Search for the frame among the kids.
        let kid;
        for (let k of t._kids) {
          if (k._frames[0] === kidFrame) {
            kid = k;
            break;
          }
        }
        if (kid) {
          // Found it. Move to it.
          t = kid;
          ti = 0;
        } else {
          // Didn't find it. Put all remaining frames into a new leaf node.
          //
          // E.g. ab:20-[c:10-Xs, d:10-Ys] + abef:10 =>
          //      ab:30-[c:10-Xs, d:10-Ys, ef:10-[]]
          kid = new TreeNode(kLeaf, pp.fs.slice(j));
          kid._addPP(pp);
          t._kids.push(kid);
          done = true;
          break;
        }
      }
    }

    if (!done) {
      // If we reach here, either:
      // - pp's frames match an existing frame sequence, in which case we
      //   just need to _addPP(); or
      // - pp's frames are a subsequence of an existing sequence, in which
      //   case we must split.

      if (ti + 1 < t._frames.length) {
        // A subsequence of an existing sequence that ends within t's internal
        // frames. Split, creating an empty node.
        //
        // E.g. abcd:20-Xs + ab:10 => ab:30-[cd:20-Xs, -:10-[]]
        t._split(ti, pp, []);

      } else if (!t._kids) {
        // This is impossible because DHAT currently produces records with
        // unique locations. If we remove addresses from frames in the future
        // then duplicate locations will occur, and the following code is how
        // it must be handled.
        throw new Error(`data file contains a repeated location (1)`);

        // Matches an existing sequence that doesn't end in node with empty
        // frames. Add the PP.
        //
        // E.g. ab:20-[] + ab:10 => ab:30-[]
        t._addPP(pp);

      } else {
        // Look for a kid with empty frames.
        let emptyKid;
        for (let k of t._kids) {
          if (k._frames.length === 0) {
            emptyKid = k;
            break;
          }
        }

        if (emptyKid) {
          // This is impossible because DHAT currently produces records with
          // unique locations. If we remove addresses from frames in the future
          // then duplicate locations will occur, and the following code is how
          // it must be handled.
          throw new Error(`data file contains a repeated location (2)`);

          // Matches an existing sequence that ends in a node with empty
          // frames. Add the PP.
          //
          // E.g. ab:20-[c:10-Xs, -:10-[]] + ab:10 => ab:30-[c:10-Xs, -:20-[]]
          t._addPP(pp);
          emptyKid._addPP(pp);

        } else {
          // A subsequence of an existing sequence that ends at the end of t's
          // internal frames. Append an empty node.
          //
          // E.g. ab:20-[c:10-Xs, d:10-Ys] + ab:10 =>
          //      ab:30-[c:10-Xs, d:10-Ys, -:10-[]]
          let newKid = new TreeNode(kLeaf, []);
          newKid._addPP(pp);

          t._kids.push(newKid);
          t._addPP(pp);
        }
      }
    }
  }
}

//------------------------------------------------------------//
//--- Pretty printers                                      ---//
//------------------------------------------------------------//

// Using Intl.NumberFormat makes things faster than using toLocaleString()
// repeatedly.
const kPFormat = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2, style: "percent" });
const kDFormat = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 }); // decimal
const kTFormat = new Intl.NumberFormat(); // time

function perc(aNum, aDenom) {
  return kPFormat.format(div(aNum, aDenom));
}

function perMinstr(aN) {
  return `${kDFormat.format(div(1000000 * aN, gData.te))}/${gData.Mtu}`;
}

function byteUnit() {
    return gData.hasOwnProperty("bu") ? gData.bsu : "byte";
}

function bytesUnit() {
    return gData.hasOwnProperty("bsu") ? gData.bsu : "bytes";
}

function blocksUnit() {
    return gData.hasOwnProperty("bksu") ? gData.bksu : "blocks";
}

function bytes(aN) {
  return `${kDFormat.format(aN)} ${bytesUnit()}`;
}

function bytesAndPerc(aN, aTotalN) {
  return `${bytes(aN)} (${perc(aN, aTotalN)})`;
}

function bytesAndPercAndRate(aN, aTotalN) {
  return `${bytes(aN)} (${perc(aN, aTotalN)}, ${perMinstr(aN)})`;
}

function blocks(aN) {
  return `${kDFormat.format(aN)} ${blocksUnit()}`;
}

function blocksAndPerc(aN, aTotalN) {
  return `${blocks(aN)} (${perc(aN, aTotalN)})`;
}

function blocksAndPercAndRate(aN, aTotalN) {
  return `${blocks(aN)} (${perc(aN, aTotalN)}, ${perMinstr(aN)})`;
}

function avgSizeBytes(aN) {
  return `avg size ${bytes(aN)}`;
}

function perByte(aN) {
  return `${kDFormat.format(aN)}/${byteUnit()}`;
}

function time(aN) {
  return `${kDFormat.format(aN)} ${gData.tu}`;
}

function avgLifetime(aN) {
  return `avg lifetime ${time(aN)}`;
}

function accesses(aAccesses) {
  // Make zero stand out.
  if (aAccesses === 0) {
    return "-";
  }

  if (aAccesses === Infinity) {
    return "∞";
  }

  // Don't use toLocaleString() -- in this case the values rarely reach
  // 100,000, and the grid formatting means the separators tend to make the
  // numbers harder to read. (And locales such as fr-FR use ' ' as the
  // separator, which conflicts with our use of ' ' between values!)
  return aAccesses.toString();
}

function ms(aNum) {
  // This function is called only a handful of times, so there is no need to
  // use Intl.NumberFormat.
  return aNum !== undefined ? `${kTFormat.format(aNum)}ms` : "n/a";
}

//------------------------------------------------------------//
//--- DOM manipulation                                     ---//
//------------------------------------------------------------//

const kDocumentTitle = "DHAT Viewer";

document.title = kDocumentTitle;

function appendElement(aP, aTagName, aClassName) {
  let e = document.createElement(aTagName);
  if (aClassName) {
    e.className = aClassName;
  }
  aP.appendChild(e);
  return e;
}

function appendElementWithText(aP, aTagName, aText, aClassName) {
  let e = appendElement(aP, aTagName, aClassName);
  e.textContent = aText;
  return e;
}

function appendText(aP, aText) {
  let e = document.createTextNode(aText);
  aP.appendChild(e);
  return e;
}

function clearDiv(aDiv) {
  // Replace aDiv with an empty node.
  assert(aDiv, "no div given");
  let tmp = aDiv.cloneNode(/* deep = */ false);
  aDiv.parentNode.replaceChild(tmp, aDiv);
  return tmp;
}

function clearMainDiv() {
  gMainDiv = clearDiv(gMainDiv);
}

function clearTimingsDiv() {
  gTimingsDiv = clearDiv(gTimingsDiv);
}

function clearMainDivWithText(aText, aClassName) {
  clearMainDiv();
  appendElementWithText(gMainDiv, "span", aText, aClassName);
}

function appendInvocationAndTimes(aP) {
  let v, v1, v2;

  v = "Invocation {\n";
  v += `  Mode:    ${gData.mode}\n`;
  v += `  Command: ${gData.cmd}\n`;
  v += `  PID:     ${gData.pid}\n`;
  v += "}\n\n";

  appendElementWithText(aP, "span", v, "invocation");

  v = "Times {\n";

  v1 = perc(gData.tg, gData.te);
  if (gData.bklt) {
    v += `  t-gmax: ${time(gData.tg)} (${v1} of program duration)\n`;
  }
  v += `  t-end:  ${time(gData.te)}\n`;

  v += "}\n\n";

  appendElementWithText(aP, "span", v, "times");
}

// Arrows indicating what state a node is in.
const kNoKidsArrow      = "─ ";     // cannot change
const kHidingKidsArrow  = "▶ ";     // expandible
const kShowingKidsArrow = "▼ ";     // collapsible

// HTML doesn't have a tree element, so we fake one with text. One nice
// consequence is that you can copy and paste the output. The non-ASCII chars
// used (for arrows and tree lines) usually reproduce well when pasted into
// textboxes.
//
// - aT: The sub-tree to append.
// - aP: Parent HTML element to append to.
// - aBolds: Which fields to highlight in the output.
// - aPc: The percentage function.
// - aCmp: The comparison function.
// - aSig: The significance function.
// - aNodeIdNums: The node ID numbers, e.g. [1,2,3], which is printed "1.2.3".
// - aNumSibs: The number of siblings that aT has.
// - aOldFrames: Frames preceding this node's frames.
// - aTlFirst: Treeline for the first line of the node.
// - aTlRest: Treeline for the other lines of the node, and its kids.
//
function appendTreeInner(aT, aP, aBolds, aCmp, aPc, aSig, aNodeIdNums,
                         aNumSibs, aOldFrames, aTlFirst, aTlRest) {
  // The primary element we'll be appending to.
  let p;

  // We build up text fragments in up to seven groups:
  // - pre-Bold1 (multiple)
  // - Bold1 (single)
  // - post-Bold1 (multiple)
  // - Bold2 (single)
  // - post-Bold2 (multiple)
  // - Bold3 (single)
  // - post-Bold3 (multiple)
  //
  // This is so that up to 3 bold sequences can be highlighted per line.
  let frags, fi;

  // Clear the text fragments.
  function clear() {
    frags = [[], undefined, [], undefined, [], undefined, []];
    fi = 0;
  }

  // Add a fragment.
  // - aShowIfInsig: should we show this even in an insignificant node?
  // - aIsBold: if this is shown, should it be bold? If undefined (as is
  //   common) it takes the same value as aShowIfInsig.
  function fr(aStr, aShowIfInsig, aIsBold) {
    if (!aShowIfInsig && aT._sig !== kSigSelf) {
      return;
    }

    if (aIsBold === undefined) {
      aIsBold = aShowIfInsig;
    }

    if (aIsBold) {
      assert(fi === 0 || fi === 2 || fi === 4, "bad fragIndex (1)");
      assert(frags[fi + 1] === undefined, "bold already here");
      frags[fi + 1] = aStr;
      fi += 2;
    } else {
      assert(fi === 0 || fi === 2 || fi === 4 || fi === 6, "bad fragIndex (2)");
      frags[fi].push(aStr);
    }
  }

  // Add a newline fragment (with a following treeline, unless aIsLast==true).
  // - aShowIfInsig: should we show this even in an insignificant node?
  // - aIsLast: is this the last newline for the node?
  function nl(aShowIfInsig, aIsLast) {
    assert(fi === 0 || fi === 2 || fi === 4 || fi === 6, "bad fragIndex (3)");
    if (!aShowIfInsig && aT._sig !== kSigSelf) {
      return;
    }

    frags[fi].push("\n");

    // Alternate the non-bold fragments (each in a text node) and bold
    // fragments (each in a span).
    if (frags[0].length > 0) {
      appendText(p, frags[0].join(""));
    }
    if (frags[1] !== undefined) {
      appendElementWithText(p, "span", frags[1], "bold");
    }
    if (frags[2].length > 0) {
      appendText(p, frags[2].join(""));
    }
    if (frags[3] !== undefined) {
      appendElementWithText(p, "span", frags[3], "bold");
    }
    if (frags[4].length > 0) {
      appendText(p, frags[4].join(""));
    }
    if (frags[5] !== undefined) {
      appendElementWithText(p, "span", frags[5], "bold");
    }
    if (frags[6].length > 0) {
      appendText(p, frags[6].join(""));
    }

    if (!aIsLast) {
      appendElementWithText(p, "span", aTlRest, "treeline");
      clear();
    }
  }

  clear();

  // Traverse the kids, aggregating insignificant nodes.
  let kids;
  if (aT._kids) {
    kids = [];
    let agg, nAgg = 0;

    for (let kid of aT._kids) {
      assert(kid._sig === kSigSelf || kid._sig === kSigDesc ||
             kid._sig === kSigNone, "kid _sig not set");

      if (kid._sig !== kSigNone) {
        // `kid` is at least partially significant. Just push it as-is.
        kids.push(kid);
      } else {
        // `kid` is insignificant. Aggregate it.
        if (!agg) {
          // We fill in ._frames below, once we know how many kids were
          // aggregated.
          agg = new TreeNode(kAgg, undefined);
          agg._sig = kSigNone;
          kids.push(agg);
        }
        nAgg++;
        agg._addNode(kid);
      }
    }

    if (agg) {
      // Fill in agg._frames.
      let insigFrame = `[${nAgg} insignificant]`;
      agg._frames = [insigFrame];
    }

    kids.sort(aCmp);
  }
  // Note: need to use `kids` for the rest of this function, not `aT._kids`.

  // Put the percentage into a colour band. The obvious way to do this is
  // with equal-sized bands (e.g. 0--20%, 20--40%, ...) but that doesn't work
  // well because in practice we have few nodes with mid-to-high percentages,
  // and many nodes with small percentages. So we use a logarithmic
  // distribution instead, so small values are better distinguished. (This is
  // reasonable in a way: a 2% node is twice as important as a 1%, a 4% node
  // is twice as important as a 2% node, etc.)
  let pc = aPc(aT);
  let lt = (aT._sig !== kSigSelf) ? "insig" // insignificant nodes
         : (pc <  1) ? "lt1"                //  0% to   0.999%
         : (pc <  2) ? "lt2"                //  1% to   1.999%
         : (pc <  4) ? "lt4"                //  2% to   3.999%
         : (pc <  8) ? "lt8"                //  4% to   7.999%
         : (pc < 16) ? "lt16"               //  8% to  15.999%
         : (pc < 32) ? "lt32"               // 16% to  31.999%
         :             "lt100";             // 32% to 100%

  // Append the primary element.
  let arrow;
  if (kids) {
    p = appendElement(aP, "span", lt + " internal expanded");
    p.onclick = toggleClass;
    arrow = kShowingKidsArrow;
  } else {
    p = appendElement(aP, "span", lt + " leaf");
    arrow = kNoKidsArrow;
  }

  // Node start: treeline and arrow.
  appendElementWithText(p, "span", aTlFirst, "treeline");
  appendElementWithText(p, "span", arrow, "arrow");

  let v1, v2, v3, v4, v5;

  // "PP" + node ID + kid count.
  v1 = aNodeIdNums.join('.');
  v2 = aNumSibs + 1;
  v3 = kids ? `(${kids.length} children) ` : "";
  fr(`PP ${v1}/${v2} ${v3}{`, true, false);
  nl(true);

  // "Total".
  v1 = bytesAndPercAndRate(aT._totalBytes, gRoot._totalBytes);
  v2 = blocksAndPercAndRate(aT._totalBlocks, gRoot._totalBlocks);
  v3 = avgSizeBytes(aT._totalAvgSizeBytes());
  v4 = avgLifetime(aT._totalAvgLifetimes());
  v5 = perc(aT._totalAvgLifetimes(), gData.te);
  fr("  Total:     ", aBolds.totalTitle);
  fr(v1, aBolds.totalBytes);
  fr(" in ");
  fr(v2, aBolds.totalBlocks);
  fr(", ", aBolds.totalAvgSizeBytes, false);
  fr(v3, aBolds.totalAvgSizeBytes);
  if (gData.bklt) {
    fr(", ", aBolds.totalAvgLifetime, false);
    fr(`${v4} (${v5} of program duration)`, aBolds.totalAvgLifetime);
  }
  nl(aBolds.totalTitle);

  if (gData.bklt) {
    // "Max".
    if (aT !== gRoot && aT._kind === kLeaf) {
      assert(!kids, "leaf node has children");
      // These percentages are relative to the local totals, not the root
      // totals.
      v1 = bytes(aT._maxBytes);
      v2 = blocks(aT._maxBlocks);
      v3 = avgSizeBytes(aT._maxAvgSizeBytes());
      fr(`  Max:       ${v1} in ${v2}, ${v3}`);
      nl();
    }

    // "At t-gmax".
    v1 = bytesAndPerc(aT._atTGmaxBytes, gRoot._atTGmaxBytes);
    v2 = blocksAndPerc(aT._atTGmaxBlocks, gRoot._atTGmaxBlocks);
    v3 = avgSizeBytes(aT._atTGmaxAvgSizeBytes());
    fr("  At t-gmax: ", aBolds.atTGmaxTitle);
    fr(v1, aBolds.atTGmaxBytes);
    fr(` in ${v2}, ${v3}`);
    nl(aBolds.atTGmaxTitle);

    // "At t-end".
    v1 = bytesAndPerc(aT._atTEndBytes, gRoot._atTEndBytes);
    v2 = blocksAndPerc(aT._atTEndBlocks, gRoot._atTEndBlocks);
    v3 = avgSizeBytes(aT._atTEndAvgSizeBytes());
    fr("  At t-end:  ", aBolds.atTEndTitle);
    fr(v1, aBolds.atTEndBytes);
    fr(` in ${v2}, ${v3}`);
    nl(aBolds.atTEndTitle);
  }

  if (gData.bkacc) {
    // "Reads".
    v1 = bytesAndPercAndRate(aT._readsBytes, gRoot._readsBytes);
    v2 = perByte(aT._readsAvgPerByte());
    fr("  Reads:     ", aBolds.readsTitle);
    fr(v1, aBolds.readsBytes);
    fr(", ", aBolds.readsBytes && aBolds.readsAvgPerByte, false);
    fr(v2, aBolds.readsAvgPerByte);
    nl(aBolds.readsTitle);

    // "Writes".
    v1 = bytesAndPercAndRate(aT._writesBytes, gRoot._writesBytes);
    v2 = perByte(aT._writesAvgPerByte());
    fr("  Writes:    ", aBolds.writesTitle);
    fr(v1, aBolds.writesBytes);
    fr(", ", aBolds.writesBytes && aBolds.writesAvgPerByte, false);
    fr(v2, aBolds.writesAvgPerByte);
    nl(aBolds.writesTitle);

    // "Accesses". We show 32 per line (but not on aggregate nodes).
    if (aT._accesses && aT._accesses.length > 0) {
      let v = "  Accesses: {";
      let prevN;
      for (let [i, n] of aT._accesses.entries()) {
        if ((i % 32) === 0) {
          fr(v);
          nl();
          v1 = i.toString().padStart(3, ' ');
          v = `    [${v1}]  `;
          v += `${accesses(n)} `;
        } else {
          // Use a ditto mark for repeats.
          v += (n === prevN && n !== 0) ? "〃 " : `${accesses(n)} `;
        }
        prevN = n;
      }
      fr(v);
      nl();

      fr("  }");
      nl();
    }
  }

  // "Allocated at".
  fr(`  ${gData.verb} at {`, true, false);
  nl(true);
  if (aT._kind === kAgg) {
    // Don't print ancestor frames; just print the "insignificant" frame.
    let isInsigFrame = (aFrm) => aFrm.indexOf(" insignificant]") >= 0;
    assert(aT._frames.length === 1 && isInsigFrame(aT._frames[0]),
           "bad aggregate node");
    fr(`    ${aT._frames[0]}`, true, false);
    nl(true);
  } else {
    // Start numbering frames from #1, unless it's the root node, in which case
    // we show "#0: [root]".
    let i = (aT === gRoot) ? 0 : 1;

    // Maybe show frames from ancestor nodes, excluding "[root]" (by starting
    // at j=1).
    for (let j = 1; j < aOldFrames.length; j++, i++) {
      fr(`    ^${i}: ${gData.ftbl[aOldFrames[j]]}`);
      nl(false);
    }
    // Show frames from this node.
    for (let j = 0; j < aT._frames.length; j++, i++) {
      fr(`    #${i}: ${gData.ftbl[aT._frames[j]]}`, true, false);
      nl(true);
    }
  }
  fr("  }", true, false);
  nl(true);

  // End of node.
  fr(`}`, true, false);
  nl(true, true);

  // Do the kids.
  if (kids) {
    assert(aT._kind !== kLeaf, "leaf node has children");

    p = appendElement(aP, "span", "kids");

    // tlFirstFor{Most,Last} are shorter than tlRestFor{Most,Last} to allow
    // space for the arrow.
    let tlFirstForMost;
    let tlRestForMost;
    if (kids.length > 1) {
      tlFirstForMost = aTlRest + "├─";
      tlRestForMost  = aTlRest + "│   ";
    }
    let tlFirstForLast = aTlRest + "└─";
    let tlRestForLast  = aTlRest + "    ";

    for (let [i, kid] of kids.entries()) {
      let n = aT._frames.length;
      aOldFrames.push(...aT._frames); // append aT._frames to aOldFrames
      aNodeIdNums.push(i + 1);
      let isLast = i === kids.length - 1;
      appendTreeInner(kid, p, aBolds, aCmp, aPc, aSig, aNodeIdNums,
                      kids.length - 1, aOldFrames,
                      !isLast ? tlFirstForMost : tlFirstForLast,
                      !isLast ? tlRestForMost : tlRestForLast);
      aNodeIdNums.pop(i);
      aOldFrames.splice(-n);         // remove aT._frames from aOldFrames
    }
  }
}

// Node significance.
// - kSigSelf: the node itself is significant. It will be shown in full.
// - kSigDesc: the node itself is insignificant, but it has one or more
//   significant descendants. (This is not possible for the straightforward
//   additive sort metrics like total-bytes, but it is possible for the
//   non-additive ones like "Total (bytes), short-lived", "Total (bytes),
//   low-access", etc.) It will be shown abbreviated.
// - kSigNone: the node itself is insignificant, and it has no significant
//   descendants. It will be aggregated.
const kSigSelf = 3;
const kSigDesc = 2;
const kSigNone = 1;

// Fill in the ._sig field of all tree nodes.
function sigTree(aT, aSig) {
  let sig = false;
  if (aT._kids) {
    for (let kid of aT._kids) {
      sig |= sigTree(kid, aSig);
    }
  }

  if (aSig(aT)) {
    aT._sig = kSigSelf;
    return true;
  }
  if (sig) {
    aT._sig = kSigDesc;
    return true;
  }
  aT._sig = kSigNone;
  return false;
}

function appendTree(aP, aBolds, aCmp, aPc, aSig) {
  sigTree(gRoot, aSig);

  appendTreeInner(gRoot, aP, aBolds, aCmp, aPc, aSig, [1], 0, [], "", "  ");
}

function appendSignificanceThreshold(aP, aSigLabel) {
  let v = `\nPP significance threshold: ${aSigLabel()}\n`;
  appendElementWithText(aP, "span", v, "threshold");
}

// Check that aElem's class list contains at least one name from aClassNames.
function classListContains(aElem, aClassNames) {
  for (let className of aClassNames) {
    if (aElem.classList.contains(className)) {
      return true;
    }
  }
  return false;
}

function assertClassListContains(aElem, aClassNames) {
  assert(aElem, "undefined elem");
  assert(classListContains(aElem, aClassNames),
         `none of ${JSON.stringify(aClassNames)} found in class list`);
}

// Called when a node with kids is clicked on.
function toggleClass(aEvent) {
  let clickedNode = aEvent.target;
  let hasKidsNode;
  if (classListContains(clickedNode, ["expanded", "collapsed"])) {
    // The click must have been on a text node, so clickedNode is the node
    // to toggle.
    hasKidsNode = clickedNode;
  } else {
    // The click must have been on a span element, so the parent node is
    // the node to toggle.
    hasKidsNode = clickedNode.parentNode;
    assertClassListContains(hasKidsNode, ["expanded", "collapsed"]);
  }
  hasKidsNode.classList.toggle("expanded");
  hasKidsNode.classList.toggle("collapsed");

  // Element order: 0: treeline span, 1: arrow span, ...
  let arrowSpan = hasKidsNode.childNodes[1];
  assertClassListContains(arrowSpan, ["arrow"]);
  if (arrowSpan.textContent === kHidingKidsArrow) {
    arrowSpan.textContent = kShowingKidsArrow;
  } else if (arrowSpan.textContent === kShowingKidsArrow) {
    arrowSpan.textContent = kHidingKidsArrow;
  } else {
    assert(false, `bad arrowSpan textContent`);
  }

  // Toggle visibility of the span containing this node's kids.
  let kidsSpan = hasKidsNode.nextSibling;
  assertClassListContains(kidsSpan, ["kids"]);
  kidsSpan.classList.toggle("hidden");
}

//------------------------------------------------------------//
//--- Top-level stuff                                      ---//
//------------------------------------------------------------//

// These arguments will be `undefined` when displayTree() is called without
// having read a file (e.g. when redisplaying with a different sort metric).
function displayTree(aTRead, aTParse, aTBuild) {
  let tRead = aTRead === undefined ? 0 : aTRead;
  let tParse = aTParse === undefined ? 0 : aTParse;
  let tBuild = aTBuild === undefined ? 0 : aTBuild;

  // Get details relating to the chosen sort metrics.
  let data = gSelectData[gSelect.selectedIndex];
  let bolds = data.bolds;
  let label = data.label();
  let cmpField = data.cmpField;
  let sig = data.sig;
  let sigLabel = data.sigLabel;
  let cmp = (aT1, aT2) => {
    // Try the specified sort metric. If that doesn't distinguish them, sort by
    // _totalBytes.
    let s1 = aT2[cmpField] - aT1[cmpField];
    return (s1 !== 0) ? s1 : aT2._totalBytes - aT1._totalBytes;
  };
  let pc = (aT) => div(aT[cmpField], gRoot[cmpField]) * 100;

  // Update the page title.
  document.title = `${kDocumentTitle} - ${gFilename} - ${label}`;

  // Build the main part of the page.
  let now = performance.now();
  clearMainDiv();
  let pre = appendElement(gMainDiv, "pre");
  appendInvocationAndTimes(pre);
  appendTree(pre, bolds, cmp, pc, sig);
  appendSignificanceThreshold(pre, sigLabel);
  let tDisplay = performance.now() - now;

  let tTotal = tRead + tParse + tBuild + tDisplay;
  clearTimingsDiv();
  let timings = `\
Processing time: \
read:${ms(aTRead)} + \
parse:${ms(aTParse)} + \
build:${ms(aTBuild)} + \
display:${ms(tDisplay)} = \
total:${ms(tTotal)}\
`;
  appendElementWithText(gTimingsDiv, "p", timings);
}

function loadFile() {
  clearMainDivWithText("Loading...");

  let now = performance.now();
  let file = gInput.files[0];
  gFilename = file.name;

  // Update the title. This will likely be overwritten very shortly, unless
  // there's a file loading problem, in which case it's nice to have the
  // correct filename in the title.
  document.title = `${kDocumentTitle} - ${gFilename}`;

  let reader = new FileReader();
  reader.onload = function(aEvent) {
    tryFunc(() => {
      let tRead = performance.now() - now;

      let data = aEvent.target.result;

      now = performance.now();
      gData = JSON.parse(data);
      let tParse = performance.now() - now;

      now = performance.now();
      buildTree();
      let tBuild = performance.now() - now;

      displayTree(tRead, tParse, tBuild);
    });
  };

  reader.onerror = function(aEvent) {
    clearMainDivWithText("Error loading file", "error");
  };

  reader.readAsText(file);
}

function changeSortMetric() {
  // If we have a tree, redisplay it for the new sort metric.
  if (gRoot) {
    tryFunc(() => {
      displayTree();
    });
  }
}

// Top-level setup when the page is first loaded.
function onLoad() {
  // Check if tests should be run.
  let params = new URLSearchParams(document.location.search.substring(1));
  let test = params.get("test");

  // The header div.
  gHeaderDiv = appendElement(document.body, "div", "section");

  // The (hidden) input element.
  let inputDiv = appendElement(gHeaderDiv, "div", "header");
  appendElementWithText(inputDiv, "div", "File");
  gInput = appendElement(inputDiv, "input", "hidden");
  gInput.type = "file";
  gInput.onchange = loadFile;

  // The button that triggers the hidden input element.
  let b = appendElementWithText(inputDiv, "button", "Load…");
  b.onclick = () => gInput.click();

  // The sort metric menu.
  let selectDiv = appendElement(gHeaderDiv, "div", "header");
  appendElementWithText(selectDiv, "div", "Sort metric");
  gSelect = appendElement(selectDiv, "select");
  gSelect.onchange = changeSortMetric;
  for (let [i, data] of gSelectData.entries()) {
    let option = appendElementWithText(gSelect, "option", data.label());
    option.value = i;
    if (data.isDefault) {
      option.selected = true;
    }
  }

  // The testing div, if necessary.
  if (test) {
    gTestingDiv = appendElement(document.body, "div", "testing");
  }

  // The main div.
  gMainDiv = appendElement(document.body, "div", "section");
  appendElementWithText(gMainDiv, "span", "Load a DHAT data file to begin");

  // The legend div. We show it even before loading a file so that new users
  // are immediately aware that it exists.
  gLegendDiv = appendElement(document.body, "div", "legend noselect");
  let p = appendElementWithText(gLegendDiv, "p", "Legend:");
  let ul = appendElement(p, "ul");
  appendElementWithText(ul, "li", "'t-gmax': time of global heap maximum " +
                                  "(as measured in bytes)");
  appendElementWithText(ul, "li", "'t-end': time of program end");
  // The file may use different units (via the `tu` and `Mtu` fields), but
  // these are the standard units so mention them here.
  appendElementWithText(ul, "li", "'instrs': instructions");
  appendElementWithText(ul, "li", "'Minstr': mega-instruction, i.e. one " +
                                  "million instructions");
  appendElementWithText(ul, "li", "'PP': program point");
  appendElementWithText(ul, "li", "'avg': average");
  appendElementWithText(ul, "li", "'-' (in accesses): zero");
  appendElementWithText(ul, "li", "'∞' (in accesses): leaf PP counts max out " +
                                  "at 65534; larger counts are treated as " +
                                  "infinity");
  appendElementWithText(ul, "li", "'〃' (in accesses): same as previous entry");

  // The timings div.
  gTimingsDiv = appendElement(document.body, "div", "timings noselect");

  if (test) {
    appendElementWithText(gHeaderDiv, "div", "TEST MODE", "header");
    var script = document.createElement("script");
    script.src = "dh_test.js";
    document.body.appendChild(script);
  }
}

