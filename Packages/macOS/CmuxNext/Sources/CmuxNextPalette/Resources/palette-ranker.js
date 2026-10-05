(() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  function __accessProp(key) {
    return this[key];
  }
  var __toCommonJS = (from) => {
    var entry = (__moduleCache ??= new WeakMap).get(from), desc;
    if (entry)
      return entry;
    entry = __defProp({}, "__esModule", { value: true });
    if (from && typeof from === "object" || typeof from === "function") {
      for (var key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(entry, key))
          __defProp(entry, key, {
            get: __accessProp.bind(from, key),
            enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable
          });
    }
    __moduleCache.set(from, entry);
    return entry;
  };
  var __moduleCache;
  var __returnValue = (v) => v;
  function __exportSetter(name, newValue) {
    this[name] = __returnValue.bind(null, newValue);
  }
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: __exportSetter.bind(all, name)
      });
  };

  // src/palette/ranker-bridge.ts
  var exports_ranker_bridge = {};
  __export(exports_ranker_bridge, {
    installPaletteRankerBridge: () => installPaletteRankerBridge
  });

  // src/palette/ranker.ts
  var disabledPenalty = 1000;
  var titleWeight = 100;
  var keywordWeight = 80;
  var subtitleWeight = 65;
  var accessoryWeight = 50;
  var maximumBoost = 60;
  var wholeTitleBonus = 500;
  var defaultHalfLife = 3 * 24 * 60 * 60;
  var cachedVersion;
  var cachedFields = [];
  function foldScalar(scalar) {
    const ascii = scalar.codePointAt(0) ?? 0;
    if (ascii >= 65 && ascii <= 90)
      return String.fromCodePoint(ascii + 32);
    const folded = scalar.normalize("NFKD").toLocaleLowerCase().replace(/[\u0300-\u036f]/gu, "");
    return Array.from(folded)[0] ?? scalar;
  }
  function charClass(scalar) {
    const value = scalar.codePointAt(0) ?? 0;
    if (value >= 97 && value <= 122)
      return "lower";
    if (value >= 65 && value <= 90)
      return "upper";
    if (value >= 48 && value <= 57)
      return "digit";
    if (scalar === " " || scalar === "\t" || "-_./:,()[]<>…、。".includes(scalar) || scalar === "（" || scalar === "）" || /\s/u.test(scalar))
      return "delimiter";
    if (value >= 12352 && value <= 12543 || value >= 13312 && value <= 40959 || value >= 44032 && value <= 55215)
      return "ideograph";
    if (/\p{Lu}/u.test(scalar))
      return "upper";
    if (/\p{Ll}/u.test(scalar))
      return "lower";
    return "other";
  }
  function maskBit(folded) {
    const value = folded.codePointAt(0) ?? 0;
    if (value >= 97 && value <= 122)
      return 1n << BigInt(value - 97);
    if (value >= 48 && value <= 57)
      return 1n << BigInt(26 + value - 48);
    if (value === 32)
      return 0n;
    return 1n << BigInt(36 + value % 28);
  }
  function maskOf(scalars) {
    return scalars.reduce((mask, scalar) => mask | maskBit(scalar), 0n);
  }
  function boundaryBonus(previous, current, first) {
    if (current === "delimiter")
      return 0;
    if (current === "ideograph")
      return first ? 10 : 3;
    if (first)
      return 10;
    if (previous === "delimiter")
      return 9;
    if (previous === "lower" && current === "upper")
      return 7;
    if (previous === "ideograph")
      return 9;
    if ((previous === "lower" || previous === "upper") && current === "digit")
      return 4;
    if (previous === "digit" && (current === "lower" || current === "upper"))
      return 4;
    return 0;
  }
  function prepareText(original) {
    const originalScalars = Array.from(original);
    const folded = [];
    const bonus = [];
    const initials = [];
    let mask = 0n;
    let previous = "delimiter";
    originalScalars.forEach((scalar, index) => {
      const foldedScalar = foldScalar(scalar);
      const current = charClass(scalar);
      const b = boundaryBonus(previous, current, index === 0);
      folded.push(foldedScalar);
      bonus.push(b);
      mask |= maskBit(foldedScalar);
      if (b >= 7 && current !== "delimiter" && current !== "ideograph")
        initials.push(foldedScalar);
      previous = current;
    });
    return { original: originalScalars, folded, bonus, initials, mask };
  }
  function makeQuery(raw) {
    const words = raw.trim().split(/\s+/u).filter(Boolean);
    const tokens = words.map((word) => Array.from(word).map(foldScalar));
    const tokenMasks = tokens.map(maskOf);
    const mask = tokenMasks.reduce((value, tokenMask) => value | tokenMask, 0n);
    const joined = tokens.flat();
    const phrase = Array.from(words.join(" ")).map(foldScalar);
    const ranges = [];
    let offset = 0;
    for (const token of tokens) {
      ranges.push({ start: offset, end: offset + token.length });
      offset += token.length;
    }
    return { raw, tokens, tokenMasks, mask, joined, phrase, flat: joined, ranges };
  }
  function queryIsEmpty(query) {
    return query.tokens.length === 0;
  }
  function hasPrefix(value, prefix) {
    if (prefix.length > value.length)
      return false;
    return prefix.every((scalar, index) => value[index] === scalar);
  }
  function substringStart(needle, folded, bonuses, requireBoundary) {
    if (!needle.length || needle.length > folded.length)
      return null;
    const first = needle[0];
    for (let start = 0;start <= folded.length - needle.length; start++) {
      if (folded[start] !== first || requireBoundary && bonuses[start] < 7)
        continue;
      let i = 1;
      while (i < needle.length && folded[start + i] === needle[i])
        i++;
      if (i === needle.length)
        return start;
    }
    return null;
  }
  function windowScore(token, folded, bonuses, start, end) {
    let score = 0;
    let tokenIndex = 0;
    let previousMatch = -2;
    let runBonus = 0;
    for (let index = start;index <= end && tokenIndex < token.length; index++) {
      if (folded[index] === token[tokenIndex]) {
        let bonus = bonuses[index];
        if (index === previousMatch + 1) {
          bonus = Math.max(bonus, runBonus);
          score += 5;
        } else {
          runBonus = bonus;
        }
        if (tokenIndex === 0)
          bonus *= 2;
        score += 16 + bonus;
        previousMatch = index;
        tokenIndex++;
      } else {
        score -= index === previousMatch + 1 ? 3 : 1;
      }
    }
    return score - Math.min(start, 12);
  }
  function forwardWindowEnd(token, folded, start) {
    let tokenIndex = 0;
    for (let index = start;index < folded.length; index++) {
      if (folded[index] === token[tokenIndex]) {
        tokenIndex++;
        if (tokenIndex === token.length)
          return index;
      }
    }
    return null;
  }
  function tokenScore(token, text) {
    if (!token.length)
      return { score: 0, start: 0, end: 0 };
    if (token.length > text.folded.length)
      return null;
    const contiguousStart = substringStart(token, text.folded, text.bonus, true);
    if (contiguousStart !== null) {
      return {
        score: windowScore(token, text.folded, text.bonus, contiguousStart, contiguousStart + token.length - 1),
        start: contiguousStart,
        end: contiguousStart + token.length - 1
      };
    }
    let tokenIndex = 0;
    let end = -1;
    for (let index = 0;index < text.folded.length; index++) {
      if (text.folded[index] === token[tokenIndex]) {
        tokenIndex++;
        if (tokenIndex === token.length) {
          end = index;
          break;
        }
      }
    }
    if (end < 0)
      return null;
    tokenIndex = token.length - 1;
    let start = end;
    for (let index = end;index >= 0; index--) {
      if (text.folded[index] === token[tokenIndex]) {
        if (tokenIndex === 0) {
          start = index;
          break;
        }
        tokenIndex--;
      }
    }
    let best = windowScore(token, text.folded, text.bonus, start, end);
    if (text.bonus[start] < 9) {
      const first = token[0];
      for (let index = 0;index < text.folded.length; index++) {
        if (text.folded[index] !== first || text.bonus[index] < 7 || index === start)
          continue;
        const alternateEnd = forwardWindowEnd(token, text.folded, index);
        if (alternateEnd === null)
          break;
        const alternate = windowScore(token, text.folded, text.bonus, index, alternateEnd);
        if (alternate > best) {
          best = alternate;
          start = index;
          end = alternateEnd;
        }
        break;
      }
    }
    return { score: best, start, end };
  }
  function phraseBonus(query, text) {
    if (!query.phrase.length || query.phrase.length > text.folded.length)
      return 0;
    if (hasPrefix(text.folded, query.phrase))
      return query.phrase.length === text.folded.length ? 220 : 90;
    if (query.joined.length >= 2 && hasPrefix(text.initials, query.joined))
      return 70;
    if (query.phrase.length >= 2 && substringStart(query.phrase, text.folded, text.bonus, true) !== null)
      return 30;
    return 0;
  }
  function fieldsFor(entry) {
    const fields = [{ text: prepareText(entry.title), weight: titleWeight }];
    if (entry.keywords?.length)
      fields.push({ text: prepareText(entry.keywords.join(" ")), weight: keywordWeight });
    if (entry.subtitle)
      fields.push({ text: prepareText(entry.subtitle), weight: subtitleWeight });
    if (entry.accessory)
      fields.push({ text: prepareText(entry.accessory), weight: accessoryWeight });
    return fields;
  }
  function fieldsForEntries(entries, version) {
    if (version !== undefined && cachedVersion === version && cachedFields.length === entries.length)
      return cachedFields;
    const fields = entries.map(fieldsFor);
    if (version !== undefined) {
      cachedVersion = version;
      cachedFields = fields;
    }
    return fields;
  }
  function scoreEntry(entry, query, fields) {
    if (queryIsEmpty(query))
      return { score: 0, highlights: [] };
    let total = 0;
    for (let tokenIndex = 0;tokenIndex < query.tokens.length; tokenIndex++) {
      const token = query.tokens[tokenIndex];
      const tokenMask = query.tokenMasks[tokenIndex];
      let best = Number.NEGATIVE_INFINITY;
      for (const field of fields) {
        if ((field.text.mask & tokenMask) !== tokenMask)
          continue;
        const match = tokenScore(token, field.text);
        if (!match)
          continue;
        best = Math.max(best, Math.trunc(match.score * field.weight / 100));
      }
      if (best === Number.NEGATIVE_INFINITY)
        return null;
      total += best;
    }
    let bonus = 0;
    let shortest = Number.POSITIVE_INFINITY;
    for (const field of fields) {
      if ((field.text.mask & query.mask) === query.mask)
        bonus = Math.max(bonus, Math.trunc(phraseBonus(query, field.text) * field.weight / 100));
      if (field.weight === 100)
        shortest = Math.min(shortest, field.text.folded.length);
    }
    const lengthPenalty = Number.isFinite(shortest) ? Math.floor(shortest / 6) : 0;
    const title = fields[0].text;
    const phraseStart = substringStart(query.phrase, title.folded, title.bonus, false);
    let highlights = [];
    if (phraseStart !== null) {
      highlights = Array.from({ length: query.phrase.length }, (_, offset) => phraseStart + offset).filter((index) => title.folded[index] !== " ");
    } else {
      const positions = new Set;
      for (let tokenIndex = 0;tokenIndex < query.tokens.length; tokenIndex++) {
        const match = tokenScore(query.tokens[tokenIndex], title);
        if (!match)
          continue;
        let matched = 0;
        for (let index = match.start;index <= match.end && matched < query.tokens[tokenIndex].length; index++) {
          if (title.folded[index] === query.tokens[tokenIndex][matched]) {
            positions.add(index);
            matched++;
          }
        }
      }
      highlights = [...positions].sort((a, b) => a - b);
    }
    return { score: total + bonus - lengthPenalty, highlights };
  }
  function frecencyScore(store, key, now) {
    if (!store?.entries || !key)
      return 0;
    const entry = store.entries[key];
    if (!entry)
      return 0;
    const halfLife = store.halfLife ?? defaultHalfLife;
    const elapsed = Math.max(0, now - entry.lastUsed);
    return entry.score * 2 ** (-elapsed / halfLife);
  }
  function frecencyBoost(store, key, now) {
    const score = frecencyScore(store, key, now);
    if (score <= 0.01)
      return 0;
    return Math.min(maximumBoost, Math.round(18 * Math.log2(1 + score)));
  }
  function topFrecencyKeys(store, limit, now) {
    if (!store?.entries)
      return [];
    return Object.keys(store.entries).map((key) => ({ key, score: frecencyScore(store, key, now) })).filter((item) => item.score >= 0.05).sort((a, b) => b.score - a.score || (a.key < b.key ? -1 : a.key > b.key ? 1 : 0)).slice(0, limit).map((item) => item.key);
  }
  function sectionOrder(sections, orders) {
    sections.sort((a, b) => {
      const left = a < orders.length ? orders[a] : Number.POSITIVE_INFINITY;
      const right = b < orders.length ? orders[b] : Number.POSITIVE_INFINITY;
      return left !== right ? left - right : a - b;
    });
  }
  function rankPaletteEmpty(request) {
    const entries = request.entries;
    const orders = request.sectionOrders ?? [];
    const store = request.frecency;
    const now = request.now ?? 0;
    const recentLimit = request.recentLimit ?? 5;
    const recent = new Set;
    const sections = [];
    if (request.showsRecent && recentLimit > 0 && store?.entries && Object.keys(store.entries).length > 0) {
      const positionByKey = new Map;
      entries.forEach((entry, index) => {
        if ((entry.isEnabled ?? true) && (entry.isVisibleWhenQueryEmpty ?? true) && entry.frecencyKey && !positionByKey.has(entry.frecencyKey))
          positionByKey.set(entry.frecencyKey, index);
      });
      const rows = topFrecencyKeys(store, recentLimit * 3, now).map((key) => positionByKey.get(key)).filter((index) => index !== undefined).slice(0, recentLimit).map((index) => ({ index, score: 0, highlights: [] }));
      if (rows.length) {
        rows.forEach((row) => recent.add(row.index));
        sections.push({ sectionIndex: null, rows });
      }
    }
    const order = [];
    const rowsBySection = new Map;
    entries.forEach((entry, index) => {
      if (!(entry.isVisibleWhenQueryEmpty ?? true) || recent.has(index))
        return;
      const section = entry.sectionIndex ?? 0;
      if (!rowsBySection.has(section))
        order.push(section);
      rowsBySection.set(section, [...rowsBySection.get(section) ?? [], { index, score: 0, highlights: [] }]);
    });
    sectionOrder(order, orders);
    sections.push(...order.map((sectionIndex) => ({ sectionIndex, rows: rowsBySection.get(sectionIndex) ?? [] })));
    return sections;
  }
  function rankPalette(request) {
    const query = makeQuery(request.query ?? "");
    if (queryIsEmpty(query))
      return rankPaletteEmpty(request);
    const entries = request.entries;
    const store = request.frecency;
    const now = request.now ?? 0;
    const gated = entries.some((entry) => entry.queryPrefix != null || entry.hidesWhenTyping === true);
    const prepared = fieldsForEntries(entries, request.version);
    const scored = [];
    entries.forEach((entry, index) => {
      if (gated && entry.hidesWhenTyping)
        return;
      if (gated && entry.queryPrefix != null && !query.raw.startsWith(entry.queryPrefix))
        return;
      const match = scoreEntry(entry, query, prepared[index]);
      if (!match)
        return;
      let score = match.score + (entry.rankBias ?? 0) + frecencyBoost(store, entry.frecencyKey, now);
      if (titleIsQuery(entry.title, query.raw))
        score += wholeTitleBonus;
      if (entry.isEnabled === false)
        score -= disabledPenalty;
      scored.push({ index, score, highlights: match.highlights });
    });
    if (request.ranksPrefixFirst) {
      const prefix = query.raw.trim().toLocaleLowerCase();
      const starts = new Set(scored.filter((item) => entries[item.index].title.toLocaleLowerCase().startsWith(prefix)).map((item) => item.index));
      scored.sort((left, right) => {
        const leftStarts = starts.has(left.index);
        const rightStarts = starts.has(right.index);
        if (leftStarts !== rightStarts)
          return leftStarts ? -1 : 1;
        if (leftStarts)
          return left.index - right.index;
        return right.score - left.score || left.index - right.index;
      });
    } else {
      scored.sort((left, right) => right.score - left.score || left.index - right.index);
    }
    const rowLimit = request.rowLimit ?? 400;
    const highlightLimit = request.highlightLimit ?? 60;
    const rows = scored.slice(0, rowLimit);
    const order = [];
    const rowsBySection = new Map;
    rows.forEach((item, rank) => {
      const section = entries[item.index].sectionIndex ?? 0;
      if (!rowsBySection.has(section))
        order.push(section);
      rowsBySection.set(section, [
        ...rowsBySection.get(section) ?? [],
        {
          index: item.index,
          score: item.score,
          highlights: rank < highlightLimit ? item.highlights : []
        }
      ]);
    });
    if (request.keepsSectionOrder)
      sectionOrder(order, request.sectionOrders ?? []);
    return order.map((sectionIndex) => ({ sectionIndex, rows: rowsBySection.get(sectionIndex) ?? [] }));
  }
  function titleIsQuery(title, raw) {
    const normalize = (text) => text.trim().replace(/(\u2026|\.\.\.)$/u, "").trim().toLocaleLowerCase();
    const query = normalize(raw);
    return query !== "" && normalize(title) === query;
  }
  function rankPaletteRequest(request) {
    return request.operation === "rankEmpty" ? rankPaletteEmpty(request) : rankPalette(request);
  }

  // src/palette/ranker-bridge.ts
  function installPaletteRankerBridge(target = globalThis) {
    target.__cmuxPaletteRank = (requestJSON) => JSON.stringify(rankPaletteRequest(JSON.parse(requestJSON)));
  }
  installPaletteRankerBridge();
})();
