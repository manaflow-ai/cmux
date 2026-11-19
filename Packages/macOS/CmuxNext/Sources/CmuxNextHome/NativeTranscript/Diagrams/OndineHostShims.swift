/// JavaScript the Ondine script needs that JavaScriptCore lacks: `TextEncoder.encodeInto`,
/// `TextDecoder.decode` (UTF-8 only) and `atob`. A browser has them; a bare `JSContext` does not.
/// Each is defined only when missing.
nonisolated let ondineHostShims = #"""
(function (g) {
  if (typeof g.TextEncoder === "undefined") {
    g.TextEncoder = function () {};
    g.TextEncoder.prototype.encodeInto = function (s, out) {
      var r = 0, w = 0, n = s.length, cap = out.length;
      while (r < n) {
        var c = s.charCodeAt(r);
        if (c >= 0xd800 && c <= 0xdbff && r + 1 < n) {
          var d = s.charCodeAt(r + 1);
          if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); }
        }
        var size = c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
        if (w + size > cap) break;
        if ((c >= 0xd800 && c <= 0xdfff)) { c = 0xfffd; size = 3; }
        if (size === 1) out[w++] = c;
        else if (size === 2) { out[w++] = 0xc0 | (c >> 6); out[w++] = 0x80 | (c & 63); }
        else if (size === 3) { out[w++] = 0xe0 | (c >> 12); out[w++] = 0x80 | ((c >> 6) & 63); out[w++] = 0x80 | (c & 63); }
        else { out[w++] = 0xf0 | (c >> 18); out[w++] = 0x80 | ((c >> 12) & 63); out[w++] = 0x80 | ((c >> 6) & 63); out[w++] = 0x80 | (c & 63); r++; }
        r++;
      }
      return { read: r, written: w };
    };
  }
  if (typeof g.TextDecoder === "undefined") {
    g.TextDecoder = function () {};
    g.TextDecoder.prototype.decode = function (b) {
      var out = [], chunk = "", i = 0, n = b ? b.length : 0;
      while (i < n) {
        var c = b[i++], cp;
        if (c < 0x80) cp = c;
        else if (c < 0xe0) cp = ((c & 31) << 6) | (b[i++] & 63);
        else if (c < 0xf0) cp = ((c & 15) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63);
        else cp = ((c & 7) << 18) | ((b[i++] & 63) << 12) | ((b[i++] & 63) << 6) | (b[i++] & 63);
        if (cp > 0xffff) { cp -= 0x10000; out.push(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023)); } else out.push(cp);
        if (out.length >= 4096) { chunk += String.fromCharCode.apply(null, out); out = []; }
      }
      return chunk + String.fromCharCode.apply(null, out);
    };
  }
  if (typeof g.atob === "undefined") {
    g.atob = function (s) {
      var t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", map = {};
      for (var k = 0; k < 64; k++) map[t.charCodeAt(k)] = k;
      var out = [], chunk = [], bits = 0, acc = 0;
      for (var i = 0; i < s.length; i++) {
        var v = map[s.charCodeAt(i)];
        if (v === undefined) continue;
        acc = (acc << 6) | v; bits += 6;
        if (bits >= 8) { bits -= 8; out.push((acc >> bits) & 255); }
        if (out.length >= 8192) { chunk.push(String.fromCharCode.apply(null, out)); out = []; }
      }
      chunk.push(String.fromCharCode.apply(null, out));
      return chunk.join("");
    };
  }
})(globalThis);
"""#
