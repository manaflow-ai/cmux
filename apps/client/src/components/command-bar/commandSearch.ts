import { fuzzyMatch } from "@/lib/vscodeFuzzyMatch";

export interface SearchableCommandItem {
  value: string;
  searchText: string;
}

export type CommandSearchIndexEntry<T extends SearchableCommandItem> = {
  item: T;
  normalizedSearchText: string;
};

export type CommandSearchIndex<T extends SearchableCommandItem> = {
  entries: Array<CommandSearchIndexEntry<T>>;
};

export const buildCommandSearchIndex = <
  T extends SearchableCommandItem,
>(items: ReadonlyArray<T>): CommandSearchIndex<T> => ({
  entries: items.map((item) => ({
    item,
    normalizedSearchText: item.searchText.toLowerCase(),
  })),
});

const SEARCH_TEXT_PART_LIMIT = 512;

const sanitizeSearchPart = (part: string): string =>
  part.trim().slice(0, SEARCH_TEXT_PART_LIMIT);

type BuildSearchTextOptions = {
  priority?: ReadonlyArray<string | undefined>;
};

export const buildSearchText = (
  label: string,
  keywords: string[] = [],
  extras: Array<string | undefined> = [],
  options?: BuildSearchTextOptions,
) => {
  const priorityParts =
    options?.priority
      ?.map((part) => (part ? sanitizeSearchPart(part) : undefined))
      .filter((part): part is string => Boolean(part)) ?? [];

  const bodyParts = [label, ...keywords, ...extras.filter((value): value is string => Boolean(value))]
    .map((part) => sanitizeSearchPart(part))
    .filter((part) => part.length > 0);

  return [...priorityParts, ...bodyParts].join(" ");
};

const normalizeLimit = (limit?: number, shouldEnforce?: boolean): number => {
  if (!shouldEnforce) {
    return Number.POSITIVE_INFINITY;
  }
  if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) {
    return Number.POSITIVE_INFINITY;
  }
  return Math.floor(limit);
};

const recomputeLowestScore = <T extends SearchableCommandItem>(
  scored: Array<{ item: T; score: number }>,
): { score: number; index: number } => {
  let lowestScore = Number.POSITIVE_INFINITY;
  let lowestIndex = -1;
  for (let i = 0; i < scored.length; i += 1) {
    const entry = scored[i]!;
    if (entry.score < lowestScore) {
      lowestScore = entry.score;
      lowestIndex = i;
    }
  }
  return { score: lowestScore, index: lowestIndex };
};

const shouldEnforceLimit = (query: string): boolean => query.length > 0;

type FilterOptions = {
  limit?: number;
};

export const filterCommandItemsWithIndex = <
  T extends SearchableCommandItem,
>(
  query: string,
  index: CommandSearchIndex<T>,
  options?: FilterOptions,
) => {
  const trimmed = query.trim();
  if (!trimmed) {
    return index.entries.map((entry) => entry.item);
  }

  const rawTokens = trimmed
    .split(/\s+/)
    .map((token) => token.trim())
    .filter((token) => token.length > 0);
  const multiWordTokens =
    rawTokens.length > 1
      ? rawTokens.map((token) => token.toLowerCase())
      : null;

  const enforceLimit = shouldEnforceLimit(trimmed);
  const limit = normalizeLimit(options?.limit, enforceLimit);
  const limitIsFinite = Number.isFinite(limit);

  const scored: Array<{ item: T; score: number }> = [];
  let lowestTrackedScore = Number.POSITIVE_INFINITY;
  let lowestTrackedIndex = -1;

  const considerScore = (entry: { item: T; score: number }) => {
    if (!limitIsFinite) {
      scored.push(entry);
      return;
    }

    if (scored.length < limit) {
      scored.push(entry);
      if (entry.score < lowestTrackedScore) {
        lowestTrackedScore = entry.score;
        lowestTrackedIndex = scored.length - 1;
      }
      if (scored.length === limit) {
        const { score, index } = recomputeLowestScore(scored);
        lowestTrackedScore = score;
        lowestTrackedIndex = index;
      }
      return;
    }

    if (entry.score <= lowestTrackedScore || lowestTrackedIndex === -1) {
      return;
    }

    scored[lowestTrackedIndex] = entry;
    const { score, index } = recomputeLowestScore(scored);
    lowestTrackedScore = score;
    lowestTrackedIndex = index;
  };

  for (const entry of index.entries) {
    if (multiWordTokens) {
      const haystack = entry.normalizedSearchText;
      const positions: number[] = [];
      for (const token of multiWordTokens) {
        const index = haystack.indexOf(token);
        if (index === -1) {
          positions.length = 0;
          break;
        }
        positions.push(index);
      }
      if (positions.length !== multiWordTokens.length) {
        continue;
      }

      const earliest = Math.min(...positions);
      const latest = Math.max(...positions);
      const span = Math.max(0, latest - earliest);
      const proximityScore = Math.max(1, 2048 - span * 8);
      const positionScore = positions.reduce((total, position, index) => {
        const decay = Math.max(1, 1024 - position * 2);
        const orderBonus =
          index > 0 && position >= positions[index - 1]! ? 32 : 0;
        return total + decay + orderBonus;
      }, 0);

      considerScore({
        item: entry.item,
        score: proximityScore + positionScore,
      });
      continue;
    }

    const score = fuzzyMatch(entry.item.searchText, trimmed);
    if (score !== null) {
      considerScore({ item: entry.item, score });
    }
  }

  scored.sort((a, b) => b.score - a.score);
  return scored.map((entry) => entry.item);
};

export const filterCommandItems = <T extends SearchableCommandItem>(
  query: string,
  items: T[],
  options?: FilterOptions,
) => {
  const index = buildCommandSearchIndex(items);
  return filterCommandItemsWithIndex(query, index, options);
};
