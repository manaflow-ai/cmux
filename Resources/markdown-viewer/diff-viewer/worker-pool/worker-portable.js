//#region rolldown:runtime
var __defProp$2 = Object.defineProperty;
var __export = (all$1) => {
	let target = {};
	for (var name in all$1) __defProp$2(target, name, {
		get: all$1[name],
		enumerable: true
	});
	return target;
};

//#endregion
//#region ../../node_modules/.bun/shiki@4.0.2/node_modules/shiki/dist/chunk-CtajNgzt.mjs
var __defProp$1 = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __exportAll = (all$1, no_symbols) => {
	let target = {};
	for (var name in all$1) {
		__defProp$1(target, name, {
			get: all$1[name],
			enumerable: true
		});
	}
	if (!no_symbols) {
		__defProp$1(target, Symbol.toStringTag, { value: "Module" });
	}
	return target;
};
var __copyProps = (to, from, except, desc) => {
	if (from && typeof from === "object" || typeof from === "function") {
		for (var keys = __getOwnPropNames(from), i$2 = 0, n = keys.length, key$1; i$2 < n; i$2++) {
			key$1 = keys[i$2];
			if (!__hasOwnProp.call(to, key$1) && key$1 !== except) {
				__defProp$1(to, key$1, {
					get: ((k$2) => from[k$2]).bind(null, key$1),
					enumerable: !(desc = __getOwnPropDesc(from, key$1)) || desc.enumerable
				});
			}
		}
	}
	return to;
};
var __reExport = (target, mod, secondTarget) => (__copyProps(target, mod, "default"), secondTarget && __copyProps(secondTarget, mod, "default"));

//#endregion
//#region ../../node_modules/.bun/@shikijs+types@4.0.2/node_modules/@shikijs/types/dist/index.mjs
var ShikiError$1 = class extends Error {
	constructor(message) {
		super(message);
		this.name = "ShikiError";
	}
};

//#endregion
//#region ../../node_modules/.bun/@shikijs+vscode-textmate@10.0.2/node_modules/@shikijs/vscode-textmate/dist/index.js
function clone(something) {
	return doClone(something);
}
function doClone(something) {
	if (Array.isArray(something)) {
		return cloneArray(something);
	}
	if (something instanceof RegExp) {
		return something;
	}
	if (typeof something === "object") {
		return cloneObj(something);
	}
	return something;
}
function cloneArray(arr) {
	let r$3 = [];
	for (let i$2 = 0, len = arr.length; i$2 < len; i$2++) {
		r$3[i$2] = doClone(arr[i$2]);
	}
	return r$3;
}
function cloneObj(obj) {
	let r$3 = {};
	for (let key$1 in obj) {
		r$3[key$1] = doClone(obj[key$1]);
	}
	return r$3;
}
function mergeObjects(target, ...sources) {
	sources.forEach((source) => {
		for (let key$1 in source) {
			target[key$1] = source[key$1];
		}
	});
	return target;
}
function basename(path) {
	const idx = ~path.lastIndexOf("/") || ~path.lastIndexOf("\\");
	if (idx === 0) {
		return path;
	} else if (~idx === path.length - 1) {
		return basename(path.substring(0, path.length - 1));
	} else {
		return path.substr(~idx + 1);
	}
}
var CAPTURING_REGEX_SOURCE = /\$(\d+)|\${(\d+):\/(downcase|upcase)}/g;
var RegexSource = class {
	static hasCaptures(regexSource) {
		if (regexSource === null) {
			return false;
		}
		CAPTURING_REGEX_SOURCE.lastIndex = 0;
		return CAPTURING_REGEX_SOURCE.test(regexSource);
	}
	static replaceCaptures(regexSource, captureSource, captureIndices) {
		return regexSource.replace(CAPTURING_REGEX_SOURCE, (match, index, commandIndex, command) => {
			let capture = captureIndices[parseInt(index || commandIndex, 10)];
			if (capture) {
				let result = captureSource.substring(capture.start, capture.end);
				while (result[0] === ".") {
					result = result.substring(1);
				}
				switch (command) {
					case "downcase": return result.toLowerCase();
					case "upcase": return result.toUpperCase();
					default: return result;
				}
			} else {
				return match;
			}
		});
	}
};
function strcmp(a$1, b$2) {
	if (a$1 < b$2) {
		return -1;
	}
	if (a$1 > b$2) {
		return 1;
	}
	return 0;
}
function strArrCmp(a$1, b$2) {
	if (a$1 === null && b$2 === null) {
		return 0;
	}
	if (!a$1) {
		return -1;
	}
	if (!b$2) {
		return 1;
	}
	let len1 = a$1.length;
	let len2 = b$2.length;
	if (len1 === len2) {
		for (let i$2 = 0; i$2 < len1; i$2++) {
			let res = strcmp(a$1[i$2], b$2[i$2]);
			if (res !== 0) {
				return res;
			}
		}
		return 0;
	}
	return len1 - len2;
}
function isValidHexColor(hex) {
	if (/^#[0-9a-f]{6}$/i.test(hex)) {
		return true;
	}
	if (/^#[0-9a-f]{8}$/i.test(hex)) {
		return true;
	}
	if (/^#[0-9a-f]{3}$/i.test(hex)) {
		return true;
	}
	if (/^#[0-9a-f]{4}$/i.test(hex)) {
		return true;
	}
	return false;
}
function escapeRegExpCharacters(value) {
	return value.replace(/[\-\\\{\}\*\+\?\|\^\$\.\,\[\]\(\)\#\s]/g, "\\$&");
}
var CachedFn = class {
	constructor(fn) {
		this.fn = fn;
	}
	cache = /* @__PURE__ */ new Map();
	get(key$1) {
		if (this.cache.has(key$1)) {
			return this.cache.get(key$1);
		}
		const value = this.fn(key$1);
		this.cache.set(key$1, value);
		return value;
	}
};
var Theme = class {
	constructor(_colorMap, _defaults, _root) {
		this._colorMap = _colorMap;
		this._defaults = _defaults;
		this._root = _root;
	}
	static createFromRawTheme(source, colorMap) {
		return this.createFromParsedTheme(parseTheme(source), colorMap);
	}
	static createFromParsedTheme(source, colorMap) {
		return resolveParsedThemeRules(source, colorMap);
	}
	_cachedMatchRoot = new CachedFn((scopeName) => this._root.match(scopeName));
	getColorMap() {
		return this._colorMap.getColorMap();
	}
	getDefaults() {
		return this._defaults;
	}
	match(scopePath) {
		if (scopePath === null) {
			return this._defaults;
		}
		const scopeName = scopePath.scopeName;
		const matchingTrieElements = this._cachedMatchRoot.get(scopeName);
		const effectiveRule = matchingTrieElements.find((v$1) => _scopePathMatchesParentScopes(scopePath.parent, v$1.parentScopes));
		if (!effectiveRule) {
			return null;
		}
		return new StyleAttributes(effectiveRule.fontStyle, effectiveRule.foreground, effectiveRule.background);
	}
};
var ScopeStack = class _ScopeStack {
	constructor(parent, scopeName) {
		this.parent = parent;
		this.scopeName = scopeName;
	}
	static push(path, scopeNames) {
		for (const name of scopeNames) {
			path = new _ScopeStack(path, name);
		}
		return path;
	}
	static from(...segments) {
		let result = null;
		for (let i$2 = 0; i$2 < segments.length; i$2++) {
			result = new _ScopeStack(result, segments[i$2]);
		}
		return result;
	}
	push(scopeName) {
		return new _ScopeStack(this, scopeName);
	}
	getSegments() {
		let item = this;
		const result = [];
		while (item) {
			result.push(item.scopeName);
			item = item.parent;
		}
		result.reverse();
		return result;
	}
	toString() {
		return this.getSegments().join(" ");
	}
	extends(other) {
		if (this === other) {
			return true;
		}
		if (this.parent === null) {
			return false;
		}
		return this.parent.extends(other);
	}
	getExtensionIfDefined(base) {
		const result = [];
		let item = this;
		while (item && item !== base) {
			result.push(item.scopeName);
			item = item.parent;
		}
		return item === base ? result.reverse() : void 0;
	}
};
function _scopePathMatchesParentScopes(scopePath, parentScopes) {
	if (parentScopes.length === 0) {
		return true;
	}
	for (let index = 0; index < parentScopes.length; index++) {
		let scopePattern = parentScopes[index];
		let scopeMustMatch = false;
		if (scopePattern === ">") {
			if (index === parentScopes.length - 1) {
				return false;
			}
			scopePattern = parentScopes[++index];
			scopeMustMatch = true;
		}
		while (scopePath) {
			if (_matchesScope(scopePath.scopeName, scopePattern)) {
				break;
			}
			if (scopeMustMatch) {
				return false;
			}
			scopePath = scopePath.parent;
		}
		if (!scopePath) {
			return false;
		}
		scopePath = scopePath.parent;
	}
	return true;
}
function _matchesScope(scopeName, scopePattern) {
	return scopePattern === scopeName || scopeName.startsWith(scopePattern) && scopeName[scopePattern.length] === ".";
}
var StyleAttributes = class {
	constructor(fontStyle, foregroundId, backgroundId) {
		this.fontStyle = fontStyle;
		this.foregroundId = foregroundId;
		this.backgroundId = backgroundId;
	}
};
function parseTheme(source) {
	if (!source) {
		return [];
	}
	if (!source.settings || !Array.isArray(source.settings)) {
		return [];
	}
	let settings = source.settings;
	let result = [], resultLen = 0;
	for (let i$2 = 0, len = settings.length; i$2 < len; i$2++) {
		let entry = settings[i$2];
		if (!entry.settings) {
			continue;
		}
		let scopes;
		if (typeof entry.scope === "string") {
			let _scope = entry.scope;
			_scope = _scope.replace(/^[,]+/, "");
			_scope = _scope.replace(/[,]+$/, "");
			scopes = _scope.split(",");
		} else if (Array.isArray(entry.scope)) {
			scopes = entry.scope;
		} else {
			scopes = [""];
		}
		let fontStyle = -1;
		if (typeof entry.settings.fontStyle === "string") {
			fontStyle = 0;
			let segments = entry.settings.fontStyle.split(" ");
			for (let j$1 = 0, lenJ = segments.length; j$1 < lenJ; j$1++) {
				let segment = segments[j$1];
				switch (segment) {
					case "italic":
						fontStyle = fontStyle | 1;
						break;
					case "bold":
						fontStyle = fontStyle | 2;
						break;
					case "underline":
						fontStyle = fontStyle | 4;
						break;
					case "strikethrough":
						fontStyle = fontStyle | 8;
						break;
				}
			}
		}
		let foreground = null;
		if (typeof entry.settings.foreground === "string" && isValidHexColor(entry.settings.foreground)) {
			foreground = entry.settings.foreground;
		}
		let background = null;
		if (typeof entry.settings.background === "string" && isValidHexColor(entry.settings.background)) {
			background = entry.settings.background;
		}
		for (let j$1 = 0, lenJ = scopes.length; j$1 < lenJ; j$1++) {
			let _scope = scopes[j$1].trim();
			let segments = _scope.split(" ");
			let scope = segments[segments.length - 1];
			let parentScopes = null;
			if (segments.length > 1) {
				parentScopes = segments.slice(0, segments.length - 1);
				parentScopes.reverse();
			}
			result[resultLen++] = new ParsedThemeRule(scope, parentScopes, i$2, fontStyle, foreground, background);
		}
	}
	return result;
}
var ParsedThemeRule = class {
	constructor(scope, parentScopes, index, fontStyle, foreground, background) {
		this.scope = scope;
		this.parentScopes = parentScopes;
		this.index = index;
		this.fontStyle = fontStyle;
		this.foreground = foreground;
		this.background = background;
	}
};
var FontStyle = /* @__PURE__ */ ((FontStyle2) => {
	FontStyle2[FontStyle2["NotSet"] = -1] = "NotSet";
	FontStyle2[FontStyle2["None"] = 0] = "None";
	FontStyle2[FontStyle2["Italic"] = 1] = "Italic";
	FontStyle2[FontStyle2["Bold"] = 2] = "Bold";
	FontStyle2[FontStyle2["Underline"] = 4] = "Underline";
	FontStyle2[FontStyle2["Strikethrough"] = 8] = "Strikethrough";
	return FontStyle2;
})(FontStyle || {});
function resolveParsedThemeRules(parsedThemeRules, _colorMap) {
	parsedThemeRules.sort((a$1, b$2) => {
		let r$3 = strcmp(a$1.scope, b$2.scope);
		if (r$3 !== 0) {
			return r$3;
		}
		r$3 = strArrCmp(a$1.parentScopes, b$2.parentScopes);
		if (r$3 !== 0) {
			return r$3;
		}
		return a$1.index - b$2.index;
	});
	let defaultFontStyle = 0;
	let defaultForeground = "#000000";
	let defaultBackground = "#ffffff";
	while (parsedThemeRules.length >= 1 && parsedThemeRules[0].scope === "") {
		let incomingDefaults = parsedThemeRules.shift();
		if (incomingDefaults.fontStyle !== -1) {
			defaultFontStyle = incomingDefaults.fontStyle;
		}
		if (incomingDefaults.foreground !== null) {
			defaultForeground = incomingDefaults.foreground;
		}
		if (incomingDefaults.background !== null) {
			defaultBackground = incomingDefaults.background;
		}
	}
	let colorMap = new ColorMap(_colorMap);
	let defaults = new StyleAttributes(defaultFontStyle, colorMap.getId(defaultForeground), colorMap.getId(defaultBackground));
	let root$1 = new ThemeTrieElement(new ThemeTrieElementRule(0, null, -1, 0, 0), []);
	for (let i$2 = 0, len = parsedThemeRules.length; i$2 < len; i$2++) {
		let rule = parsedThemeRules[i$2];
		root$1.insert(0, rule.scope, rule.parentScopes, rule.fontStyle, colorMap.getId(rule.foreground), colorMap.getId(rule.background));
	}
	return new Theme(colorMap, defaults, root$1);
}
var ColorMap = class {
	_isFrozen;
	_lastColorId;
	_id2color;
	_color2id;
	constructor(_colorMap) {
		this._lastColorId = 0;
		this._id2color = [];
		this._color2id = /* @__PURE__ */ Object.create(null);
		if (Array.isArray(_colorMap)) {
			this._isFrozen = true;
			for (let i$2 = 0, len = _colorMap.length; i$2 < len; i$2++) {
				this._color2id[_colorMap[i$2]] = i$2;
				this._id2color[i$2] = _colorMap[i$2];
			}
		} else {
			this._isFrozen = false;
		}
	}
	getId(color) {
		if (color === null) {
			return 0;
		}
		color = color.toUpperCase();
		let value = this._color2id[color];
		if (value) {
			return value;
		}
		if (this._isFrozen) {
			throw new Error(`Missing color in color map - ${color}`);
		}
		value = ++this._lastColorId;
		this._color2id[color] = value;
		this._id2color[value] = color;
		return value;
	}
	getColorMap() {
		return this._id2color.slice(0);
	}
};
var emptyParentScopes = Object.freeze([]);
var ThemeTrieElementRule = class _ThemeTrieElementRule {
	scopeDepth;
	parentScopes;
	fontStyle;
	foreground;
	background;
	constructor(scopeDepth, parentScopes, fontStyle, foreground, background) {
		this.scopeDepth = scopeDepth;
		this.parentScopes = parentScopes || emptyParentScopes;
		this.fontStyle = fontStyle;
		this.foreground = foreground;
		this.background = background;
	}
	clone() {
		return new _ThemeTrieElementRule(this.scopeDepth, this.parentScopes, this.fontStyle, this.foreground, this.background);
	}
	static cloneArr(arr) {
		let r$3 = [];
		for (let i$2 = 0, len = arr.length; i$2 < len; i$2++) {
			r$3[i$2] = arr[i$2].clone();
		}
		return r$3;
	}
	acceptOverwrite(scopeDepth, fontStyle, foreground, background) {
		if (this.scopeDepth > scopeDepth) {
			console.log("how did this happen?");
		} else {
			this.scopeDepth = scopeDepth;
		}
		if (fontStyle !== -1) {
			this.fontStyle = fontStyle;
		}
		if (foreground !== 0) {
			this.foreground = foreground;
		}
		if (background !== 0) {
			this.background = background;
		}
	}
};
var ThemeTrieElement = class _ThemeTrieElement {
	constructor(_mainRule, rulesWithParentScopes = [], _children = {}) {
		this._mainRule = _mainRule;
		this._children = _children;
		this._rulesWithParentScopes = rulesWithParentScopes;
	}
	_rulesWithParentScopes;
	static _cmpBySpecificity(a$1, b$2) {
		if (a$1.scopeDepth !== b$2.scopeDepth) {
			return b$2.scopeDepth - a$1.scopeDepth;
		}
		let aParentIndex = 0;
		let bParentIndex = 0;
		while (true) {
			if (a$1.parentScopes[aParentIndex] === ">") {
				aParentIndex++;
			}
			if (b$2.parentScopes[bParentIndex] === ">") {
				bParentIndex++;
			}
			if (aParentIndex >= a$1.parentScopes.length || bParentIndex >= b$2.parentScopes.length) {
				break;
			}
			const parentScopeLengthDiff = b$2.parentScopes[bParentIndex].length - a$1.parentScopes[aParentIndex].length;
			if (parentScopeLengthDiff !== 0) {
				return parentScopeLengthDiff;
			}
			aParentIndex++;
			bParentIndex++;
		}
		return b$2.parentScopes.length - a$1.parentScopes.length;
	}
	match(scope) {
		if (scope !== "") {
			let dotIndex = scope.indexOf(".");
			let head$1;
			let tail;
			if (dotIndex === -1) {
				head$1 = scope;
				tail = "";
			} else {
				head$1 = scope.substring(0, dotIndex);
				tail = scope.substring(dotIndex + 1);
			}
			if (this._children.hasOwnProperty(head$1)) {
				return this._children[head$1].match(tail);
			}
		}
		const rules = this._rulesWithParentScopes.concat(this._mainRule);
		rules.sort(_ThemeTrieElement._cmpBySpecificity);
		return rules;
	}
	insert(scopeDepth, scope, parentScopes, fontStyle, foreground, background) {
		if (scope === "") {
			this._doInsertHere(scopeDepth, parentScopes, fontStyle, foreground, background);
			return;
		}
		let dotIndex = scope.indexOf(".");
		let head$1;
		let tail;
		if (dotIndex === -1) {
			head$1 = scope;
			tail = "";
		} else {
			head$1 = scope.substring(0, dotIndex);
			tail = scope.substring(dotIndex + 1);
		}
		let child;
		if (this._children.hasOwnProperty(head$1)) {
			child = this._children[head$1];
		} else {
			child = new _ThemeTrieElement(this._mainRule.clone(), ThemeTrieElementRule.cloneArr(this._rulesWithParentScopes));
			this._children[head$1] = child;
		}
		child.insert(scopeDepth + 1, tail, parentScopes, fontStyle, foreground, background);
	}
	_doInsertHere(scopeDepth, parentScopes, fontStyle, foreground, background) {
		if (parentScopes === null) {
			this._mainRule.acceptOverwrite(scopeDepth, fontStyle, foreground, background);
			return;
		}
		for (let i$2 = 0, len = this._rulesWithParentScopes.length; i$2 < len; i$2++) {
			let rule = this._rulesWithParentScopes[i$2];
			if (strArrCmp(rule.parentScopes, parentScopes) === 0) {
				rule.acceptOverwrite(scopeDepth, fontStyle, foreground, background);
				return;
			}
		}
		if (fontStyle === -1) {
			fontStyle = this._mainRule.fontStyle;
		}
		if (foreground === 0) {
			foreground = this._mainRule.foreground;
		}
		if (background === 0) {
			background = this._mainRule.background;
		}
		this._rulesWithParentScopes.push(new ThemeTrieElementRule(scopeDepth, parentScopes, fontStyle, foreground, background));
	}
};
var EncodedTokenMetadata = class _EncodedTokenMetadata {
	static toBinaryStr(encodedTokenAttributes) {
		return encodedTokenAttributes.toString(2).padStart(32, "0");
	}
	static print(encodedTokenAttributes) {
		const languageId = _EncodedTokenMetadata.getLanguageId(encodedTokenAttributes);
		const tokenType = _EncodedTokenMetadata.getTokenType(encodedTokenAttributes);
		const fontStyle = _EncodedTokenMetadata.getFontStyle(encodedTokenAttributes);
		const foreground = _EncodedTokenMetadata.getForeground(encodedTokenAttributes);
		const background = _EncodedTokenMetadata.getBackground(encodedTokenAttributes);
		console.log({
			languageId,
			tokenType,
			fontStyle,
			foreground,
			background
		});
	}
	static getLanguageId(encodedTokenAttributes) {
		return (encodedTokenAttributes & 255) >>> 0;
	}
	static getTokenType(encodedTokenAttributes) {
		return (encodedTokenAttributes & 768) >>> 8;
	}
	static containsBalancedBrackets(encodedTokenAttributes) {
		return (encodedTokenAttributes & 1024) !== 0;
	}
	static getFontStyle(encodedTokenAttributes) {
		return (encodedTokenAttributes & 30720) >>> 11;
	}
	static getForeground(encodedTokenAttributes) {
		return (encodedTokenAttributes & 16744448) >>> 15;
	}
	static getBackground(encodedTokenAttributes) {
		return (encodedTokenAttributes & 4278190080) >>> 24;
	}
	/**
	* Updates the fields in `metadata`.
	* A value of `0`, `NotSet` or `null` indicates that the corresponding field should be left as is.
	*/
	static set(encodedTokenAttributes, languageId, tokenType, containsBalancedBrackets, fontStyle, foreground, background) {
		let _languageId = _EncodedTokenMetadata.getLanguageId(encodedTokenAttributes);
		let _tokenType = _EncodedTokenMetadata.getTokenType(encodedTokenAttributes);
		let _containsBalancedBracketsBit = _EncodedTokenMetadata.containsBalancedBrackets(encodedTokenAttributes) ? 1 : 0;
		let _fontStyle = _EncodedTokenMetadata.getFontStyle(encodedTokenAttributes);
		let _foreground = _EncodedTokenMetadata.getForeground(encodedTokenAttributes);
		let _background = _EncodedTokenMetadata.getBackground(encodedTokenAttributes);
		if (languageId !== 0) {
			_languageId = languageId;
		}
		if (tokenType !== 8) {
			_tokenType = fromOptionalTokenType(tokenType);
		}
		if (containsBalancedBrackets !== null) {
			_containsBalancedBracketsBit = containsBalancedBrackets ? 1 : 0;
		}
		if (fontStyle !== -1) {
			_fontStyle = fontStyle;
		}
		if (foreground !== 0) {
			_foreground = foreground;
		}
		if (background !== 0) {
			_background = background;
		}
		return (_languageId << 0 | _tokenType << 8 | _containsBalancedBracketsBit << 10 | _fontStyle << 11 | _foreground << 15 | _background << 24) >>> 0;
	}
};
function toOptionalTokenType(standardType) {
	return standardType;
}
function fromOptionalTokenType(standardType) {
	return standardType;
}
function createMatchers(selector, matchesName) {
	const results = [];
	const tokenizer = newTokenizer(selector);
	let token$1 = tokenizer.next();
	while (token$1 !== null) {
		let priority = 0;
		if (token$1.length === 2 && token$1.charAt(1) === ":") {
			switch (token$1.charAt(0)) {
				case "R":
					priority = 1;
					break;
				case "L":
					priority = -1;
					break;
				default: console.log(`Unknown priority ${token$1} in scope selector`);
			}
			token$1 = tokenizer.next();
		}
		let matcher = parseConjunction();
		results.push({
			matcher,
			priority
		});
		if (token$1 !== ",") {
			break;
		}
		token$1 = tokenizer.next();
	}
	return results;
	function parseOperand() {
		if (token$1 === "-") {
			token$1 = tokenizer.next();
			const expressionToNegate = parseOperand();
			return (matcherInput) => !!expressionToNegate && !expressionToNegate(matcherInput);
		}
		if (token$1 === "(") {
			token$1 = tokenizer.next();
			const expressionInParents = parseInnerExpression();
			if (token$1 === ")") {
				token$1 = tokenizer.next();
			}
			return expressionInParents;
		}
		if (isIdentifier(token$1)) {
			const identifiers = [];
			do {
				identifiers.push(token$1);
				token$1 = tokenizer.next();
			} while (isIdentifier(token$1));
			return (matcherInput) => matchesName(identifiers, matcherInput);
		}
		return null;
	}
	function parseConjunction() {
		const matchers$1 = [];
		let matcher = parseOperand();
		while (matcher) {
			matchers$1.push(matcher);
			matcher = parseOperand();
		}
		return (matcherInput) => matchers$1.every((matcher2) => matcher2(matcherInput));
	}
	function parseInnerExpression() {
		const matchers$1 = [];
		let matcher = parseConjunction();
		while (matcher) {
			matchers$1.push(matcher);
			if (token$1 === "|" || token$1 === ",") {
				do {
					token$1 = tokenizer.next();
				} while (token$1 === "|" || token$1 === ",");
			} else {
				break;
			}
			matcher = parseConjunction();
		}
		return (matcherInput) => matchers$1.some((matcher2) => matcher2(matcherInput));
	}
}
function isIdentifier(token$1) {
	return !!token$1 && !!token$1.match(/[\w\.:]+/);
}
function newTokenizer(input) {
	let regex = /([LR]:|[\w\.:][\w\.:\-]*|[\,\|\-\(\)])/g;
	let match = regex.exec(input);
	return { next: () => {
		if (!match) {
			return null;
		}
		const res = match[0];
		match = regex.exec(input);
		return res;
	} };
}
var FindOption = /* @__PURE__ */ ((FindOption2) => {
	FindOption2[FindOption2["None"] = 0] = "None";
	FindOption2[FindOption2["NotBeginString"] = 1] = "NotBeginString";
	FindOption2[FindOption2["NotEndString"] = 2] = "NotEndString";
	FindOption2[FindOption2["NotBeginPosition"] = 4] = "NotBeginPosition";
	FindOption2[FindOption2["DebugCall"] = 8] = "DebugCall";
	return FindOption2;
})(FindOption || {});
function disposeOnigString(str) {
	if (typeof str.dispose === "function") {
		str.dispose();
	}
}
var TopLevelRuleReference = class {
	constructor(scopeName) {
		this.scopeName = scopeName;
	}
	toKey() {
		return this.scopeName;
	}
};
var TopLevelRepositoryRuleReference = class {
	constructor(scopeName, ruleName) {
		this.scopeName = scopeName;
		this.ruleName = ruleName;
	}
	toKey() {
		return `${this.scopeName}#${this.ruleName}`;
	}
};
var ExternalReferenceCollector = class {
	_references = [];
	_seenReferenceKeys = /* @__PURE__ */ new Set();
	get references() {
		return this._references;
	}
	visitedRule = /* @__PURE__ */ new Set();
	add(reference) {
		const key$1 = reference.toKey();
		if (this._seenReferenceKeys.has(key$1)) {
			return;
		}
		this._seenReferenceKeys.add(key$1);
		this._references.push(reference);
	}
};
var ScopeDependencyProcessor = class {
	constructor(repo, initialScopeName) {
		this.repo = repo;
		this.initialScopeName = initialScopeName;
		this.seenFullScopeRequests.add(this.initialScopeName);
		this.Q = [new TopLevelRuleReference(this.initialScopeName)];
	}
	seenFullScopeRequests = /* @__PURE__ */ new Set();
	seenPartialScopeRequests = /* @__PURE__ */ new Set();
	Q;
	processQueue() {
		const q$1 = this.Q;
		this.Q = [];
		const deps = new ExternalReferenceCollector();
		for (const dep of q$1) {
			collectReferencesOfReference(dep, this.initialScopeName, this.repo, deps);
		}
		for (const dep of deps.references) {
			if (dep instanceof TopLevelRuleReference) {
				if (this.seenFullScopeRequests.has(dep.scopeName)) {
					continue;
				}
				this.seenFullScopeRequests.add(dep.scopeName);
				this.Q.push(dep);
			} else {
				if (this.seenFullScopeRequests.has(dep.scopeName)) {
					continue;
				}
				if (this.seenPartialScopeRequests.has(dep.toKey())) {
					continue;
				}
				this.seenPartialScopeRequests.add(dep.toKey());
				this.Q.push(dep);
			}
		}
	}
};
function collectReferencesOfReference(reference, baseGrammarScopeName, repo, result) {
	const selfGrammar = repo.lookup(reference.scopeName);
	if (!selfGrammar) {
		if (reference.scopeName === baseGrammarScopeName) {
			throw new Error(`No grammar provided for <${baseGrammarScopeName}>`);
		}
		return;
	}
	const baseGrammar = repo.lookup(baseGrammarScopeName);
	if (reference instanceof TopLevelRuleReference) {
		collectExternalReferencesInTopLevelRule({
			baseGrammar,
			selfGrammar
		}, result);
	} else {
		collectExternalReferencesInTopLevelRepositoryRule(reference.ruleName, {
			baseGrammar,
			selfGrammar,
			repository: selfGrammar.repository
		}, result);
	}
	const injections = repo.injections(reference.scopeName);
	if (injections) {
		for (const injection of injections) {
			result.add(new TopLevelRuleReference(injection));
		}
	}
}
function collectExternalReferencesInTopLevelRepositoryRule(ruleName, context, result) {
	if (context.repository && context.repository[ruleName]) {
		const rule = context.repository[ruleName];
		collectExternalReferencesInRules([rule], context, result);
	}
}
function collectExternalReferencesInTopLevelRule(context, result) {
	if (context.selfGrammar.patterns && Array.isArray(context.selfGrammar.patterns)) {
		collectExternalReferencesInRules(context.selfGrammar.patterns, {
			...context,
			repository: context.selfGrammar.repository
		}, result);
	}
	if (context.selfGrammar.injections) {
		collectExternalReferencesInRules(Object.values(context.selfGrammar.injections), {
			...context,
			repository: context.selfGrammar.repository
		}, result);
	}
}
function collectExternalReferencesInRules(rules, context, result) {
	for (const rule of rules) {
		if (result.visitedRule.has(rule)) {
			continue;
		}
		result.visitedRule.add(rule);
		const patternRepository = rule.repository ? mergeObjects({}, context.repository, rule.repository) : context.repository;
		if (Array.isArray(rule.patterns)) {
			collectExternalReferencesInRules(rule.patterns, {
				...context,
				repository: patternRepository
			}, result);
		}
		const include = rule.include;
		if (!include) {
			continue;
		}
		const reference = parseInclude(include);
		switch (reference.kind) {
			case 0:
				collectExternalReferencesInTopLevelRule({
					...context,
					selfGrammar: context.baseGrammar
				}, result);
				break;
			case 1:
				collectExternalReferencesInTopLevelRule(context, result);
				break;
			case 2:
				collectExternalReferencesInTopLevelRepositoryRule(reference.ruleName, {
					...context,
					repository: patternRepository
				}, result);
				break;
			case 3:
			case 4:
				const selfGrammar = reference.scopeName === context.selfGrammar.scopeName ? context.selfGrammar : reference.scopeName === context.baseGrammar.scopeName ? context.baseGrammar : void 0;
				if (selfGrammar) {
					const newContext = {
						baseGrammar: context.baseGrammar,
						selfGrammar,
						repository: patternRepository
					};
					if (reference.kind === 4) {
						collectExternalReferencesInTopLevelRepositoryRule(reference.ruleName, newContext, result);
					} else {
						collectExternalReferencesInTopLevelRule(newContext, result);
					}
				} else {
					if (reference.kind === 4) {
						result.add(new TopLevelRepositoryRuleReference(reference.scopeName, reference.ruleName));
					} else {
						result.add(new TopLevelRuleReference(reference.scopeName));
					}
				}
				break;
		}
	}
}
var BaseReference = class {
	kind = 0;
};
var SelfReference = class {
	kind = 1;
};
var RelativeReference = class {
	constructor(ruleName) {
		this.ruleName = ruleName;
	}
	kind = 2;
};
var TopLevelReference = class {
	constructor(scopeName) {
		this.scopeName = scopeName;
	}
	kind = 3;
};
var TopLevelRepositoryReference = class {
	constructor(scopeName, ruleName) {
		this.scopeName = scopeName;
		this.ruleName = ruleName;
	}
	kind = 4;
};
function parseInclude(include) {
	if (include === "$base") {
		return new BaseReference();
	} else if (include === "$self") {
		return new SelfReference();
	}
	const indexOfSharp = include.indexOf("#");
	if (indexOfSharp === -1) {
		return new TopLevelReference(include);
	} else if (indexOfSharp === 0) {
		return new RelativeReference(include.substring(1));
	} else {
		const scopeName = include.substring(0, indexOfSharp);
		const ruleName = include.substring(indexOfSharp + 1);
		return new TopLevelRepositoryReference(scopeName, ruleName);
	}
}
var HAS_BACK_REFERENCES = /\\(\d+)/;
var BACK_REFERENCING_END = /\\(\d+)/g;
var ruleIdSymbol = Symbol("RuleId");
var endRuleId = -1;
var whileRuleId = -2;
function ruleIdFromNumber(id) {
	return id;
}
function ruleIdToNumber(id) {
	return id;
}
var Rule = class {
	$location;
	id;
	_nameIsCapturing;
	_name;
	_contentNameIsCapturing;
	_contentName;
	constructor($location, id, name, contentName) {
		this.$location = $location;
		this.id = id;
		this._name = name || null;
		this._nameIsCapturing = RegexSource.hasCaptures(this._name);
		this._contentName = contentName || null;
		this._contentNameIsCapturing = RegexSource.hasCaptures(this._contentName);
	}
	get debugName() {
		const location = this.$location ? `${basename(this.$location.filename)}:${this.$location.line}` : "unknown";
		return `${this.constructor.name}#${this.id} @ ${location}`;
	}
	getName(lineText, captureIndices) {
		if (!this._nameIsCapturing || this._name === null || lineText === null || captureIndices === null) {
			return this._name;
		}
		return RegexSource.replaceCaptures(this._name, lineText, captureIndices);
	}
	getContentName(lineText, captureIndices) {
		if (!this._contentNameIsCapturing || this._contentName === null) {
			return this._contentName;
		}
		return RegexSource.replaceCaptures(this._contentName, lineText, captureIndices);
	}
};
var CaptureRule = class extends Rule {
	retokenizeCapturedWithRuleId;
	constructor($location, id, name, contentName, retokenizeCapturedWithRuleId) {
		super($location, id, name, contentName);
		this.retokenizeCapturedWithRuleId = retokenizeCapturedWithRuleId;
	}
	dispose() {}
	collectPatterns(grammar, out) {
		throw new Error("Not supported!");
	}
	compile(grammar, endRegexSource) {
		throw new Error("Not supported!");
	}
	compileAG(grammar, endRegexSource, allowA, allowG) {
		throw new Error("Not supported!");
	}
};
var MatchRule = class extends Rule {
	_match;
	captures;
	_cachedCompiledPatterns;
	constructor($location, id, name, match, captures) {
		super($location, id, name, null);
		this._match = new RegExpSource(match, this.id);
		this.captures = captures;
		this._cachedCompiledPatterns = null;
	}
	dispose() {
		if (this._cachedCompiledPatterns) {
			this._cachedCompiledPatterns.dispose();
			this._cachedCompiledPatterns = null;
		}
	}
	get debugMatchRegExp() {
		return `${this._match.source}`;
	}
	collectPatterns(grammar, out) {
		out.push(this._match);
	}
	compile(grammar, endRegexSource) {
		return this._getCachedCompiledPatterns(grammar).compile(grammar);
	}
	compileAG(grammar, endRegexSource, allowA, allowG) {
		return this._getCachedCompiledPatterns(grammar).compileAG(grammar, allowA, allowG);
	}
	_getCachedCompiledPatterns(grammar) {
		if (!this._cachedCompiledPatterns) {
			this._cachedCompiledPatterns = new RegExpSourceList();
			this.collectPatterns(grammar, this._cachedCompiledPatterns);
		}
		return this._cachedCompiledPatterns;
	}
};
var IncludeOnlyRule = class extends Rule {
	hasMissingPatterns;
	patterns;
	_cachedCompiledPatterns;
	constructor($location, id, name, contentName, patterns) {
		super($location, id, name, contentName);
		this.patterns = patterns.patterns;
		this.hasMissingPatterns = patterns.hasMissingPatterns;
		this._cachedCompiledPatterns = null;
	}
	dispose() {
		if (this._cachedCompiledPatterns) {
			this._cachedCompiledPatterns.dispose();
			this._cachedCompiledPatterns = null;
		}
	}
	collectPatterns(grammar, out) {
		for (const pattern of this.patterns) {
			const rule = grammar.getRule(pattern);
			rule.collectPatterns(grammar, out);
		}
	}
	compile(grammar, endRegexSource) {
		return this._getCachedCompiledPatterns(grammar).compile(grammar);
	}
	compileAG(grammar, endRegexSource, allowA, allowG) {
		return this._getCachedCompiledPatterns(grammar).compileAG(grammar, allowA, allowG);
	}
	_getCachedCompiledPatterns(grammar) {
		if (!this._cachedCompiledPatterns) {
			this._cachedCompiledPatterns = new RegExpSourceList();
			this.collectPatterns(grammar, this._cachedCompiledPatterns);
		}
		return this._cachedCompiledPatterns;
	}
};
var BeginEndRule = class extends Rule {
	_begin;
	beginCaptures;
	_end;
	endHasBackReferences;
	endCaptures;
	applyEndPatternLast;
	hasMissingPatterns;
	patterns;
	_cachedCompiledPatterns;
	constructor($location, id, name, contentName, begin, beginCaptures, end, endCaptures, applyEndPatternLast, patterns) {
		super($location, id, name, contentName);
		this._begin = new RegExpSource(begin, this.id);
		this.beginCaptures = beginCaptures;
		this._end = new RegExpSource(end ? end : "￿", -1);
		this.endHasBackReferences = this._end.hasBackReferences;
		this.endCaptures = endCaptures;
		this.applyEndPatternLast = applyEndPatternLast || false;
		this.patterns = patterns.patterns;
		this.hasMissingPatterns = patterns.hasMissingPatterns;
		this._cachedCompiledPatterns = null;
	}
	dispose() {
		if (this._cachedCompiledPatterns) {
			this._cachedCompiledPatterns.dispose();
			this._cachedCompiledPatterns = null;
		}
	}
	get debugBeginRegExp() {
		return `${this._begin.source}`;
	}
	get debugEndRegExp() {
		return `${this._end.source}`;
	}
	getEndWithResolvedBackReferences(lineText, captureIndices) {
		return this._end.resolveBackReferences(lineText, captureIndices);
	}
	collectPatterns(grammar, out) {
		out.push(this._begin);
	}
	compile(grammar, endRegexSource) {
		return this._getCachedCompiledPatterns(grammar, endRegexSource).compile(grammar);
	}
	compileAG(grammar, endRegexSource, allowA, allowG) {
		return this._getCachedCompiledPatterns(grammar, endRegexSource).compileAG(grammar, allowA, allowG);
	}
	_getCachedCompiledPatterns(grammar, endRegexSource) {
		if (!this._cachedCompiledPatterns) {
			this._cachedCompiledPatterns = new RegExpSourceList();
			for (const pattern of this.patterns) {
				const rule = grammar.getRule(pattern);
				rule.collectPatterns(grammar, this._cachedCompiledPatterns);
			}
			if (this.applyEndPatternLast) {
				this._cachedCompiledPatterns.push(this._end.hasBackReferences ? this._end.clone() : this._end);
			} else {
				this._cachedCompiledPatterns.unshift(this._end.hasBackReferences ? this._end.clone() : this._end);
			}
		}
		if (this._end.hasBackReferences) {
			if (this.applyEndPatternLast) {
				this._cachedCompiledPatterns.setSource(this._cachedCompiledPatterns.length() - 1, endRegexSource);
			} else {
				this._cachedCompiledPatterns.setSource(0, endRegexSource);
			}
		}
		return this._cachedCompiledPatterns;
	}
};
var BeginWhileRule = class extends Rule {
	_begin;
	beginCaptures;
	whileCaptures;
	_while;
	whileHasBackReferences;
	hasMissingPatterns;
	patterns;
	_cachedCompiledPatterns;
	_cachedCompiledWhilePatterns;
	constructor($location, id, name, contentName, begin, beginCaptures, _while, whileCaptures, patterns) {
		super($location, id, name, contentName);
		this._begin = new RegExpSource(begin, this.id);
		this.beginCaptures = beginCaptures;
		this.whileCaptures = whileCaptures;
		this._while = new RegExpSource(_while, whileRuleId);
		this.whileHasBackReferences = this._while.hasBackReferences;
		this.patterns = patterns.patterns;
		this.hasMissingPatterns = patterns.hasMissingPatterns;
		this._cachedCompiledPatterns = null;
		this._cachedCompiledWhilePatterns = null;
	}
	dispose() {
		if (this._cachedCompiledPatterns) {
			this._cachedCompiledPatterns.dispose();
			this._cachedCompiledPatterns = null;
		}
		if (this._cachedCompiledWhilePatterns) {
			this._cachedCompiledWhilePatterns.dispose();
			this._cachedCompiledWhilePatterns = null;
		}
	}
	get debugBeginRegExp() {
		return `${this._begin.source}`;
	}
	get debugWhileRegExp() {
		return `${this._while.source}`;
	}
	getWhileWithResolvedBackReferences(lineText, captureIndices) {
		return this._while.resolveBackReferences(lineText, captureIndices);
	}
	collectPatterns(grammar, out) {
		out.push(this._begin);
	}
	compile(grammar, endRegexSource) {
		return this._getCachedCompiledPatterns(grammar).compile(grammar);
	}
	compileAG(grammar, endRegexSource, allowA, allowG) {
		return this._getCachedCompiledPatterns(grammar).compileAG(grammar, allowA, allowG);
	}
	_getCachedCompiledPatterns(grammar) {
		if (!this._cachedCompiledPatterns) {
			this._cachedCompiledPatterns = new RegExpSourceList();
			for (const pattern of this.patterns) {
				const rule = grammar.getRule(pattern);
				rule.collectPatterns(grammar, this._cachedCompiledPatterns);
			}
		}
		return this._cachedCompiledPatterns;
	}
	compileWhile(grammar, endRegexSource) {
		return this._getCachedCompiledWhilePatterns(grammar, endRegexSource).compile(grammar);
	}
	compileWhileAG(grammar, endRegexSource, allowA, allowG) {
		return this._getCachedCompiledWhilePatterns(grammar, endRegexSource).compileAG(grammar, allowA, allowG);
	}
	_getCachedCompiledWhilePatterns(grammar, endRegexSource) {
		if (!this._cachedCompiledWhilePatterns) {
			this._cachedCompiledWhilePatterns = new RegExpSourceList();
			this._cachedCompiledWhilePatterns.push(this._while.hasBackReferences ? this._while.clone() : this._while);
		}
		if (this._while.hasBackReferences) {
			this._cachedCompiledWhilePatterns.setSource(0, endRegexSource ? endRegexSource : "￿");
		}
		return this._cachedCompiledWhilePatterns;
	}
};
var RuleFactory = class _RuleFactory {
	static createCaptureRule(helper, $location, name, contentName, retokenizeCapturedWithRuleId) {
		return helper.registerRule((id) => {
			return new CaptureRule($location, id, name, contentName, retokenizeCapturedWithRuleId);
		});
	}
	static getCompiledRuleId(desc, helper, repository) {
		if (!desc.id) {
			helper.registerRule((id) => {
				desc.id = id;
				if (desc.match) {
					return new MatchRule(desc.$vscodeTextmateLocation, desc.id, desc.name, desc.match, _RuleFactory._compileCaptures(desc.captures, helper, repository));
				}
				if (typeof desc.begin === "undefined") {
					if (desc.repository) {
						repository = mergeObjects({}, repository, desc.repository);
					}
					let patterns = desc.patterns;
					if (typeof patterns === "undefined" && desc.include) {
						patterns = [{ include: desc.include }];
					}
					return new IncludeOnlyRule(desc.$vscodeTextmateLocation, desc.id, desc.name, desc.contentName, _RuleFactory._compilePatterns(patterns, helper, repository));
				}
				if (desc.while) {
					return new BeginWhileRule(desc.$vscodeTextmateLocation, desc.id, desc.name, desc.contentName, desc.begin, _RuleFactory._compileCaptures(desc.beginCaptures || desc.captures, helper, repository), desc.while, _RuleFactory._compileCaptures(desc.whileCaptures || desc.captures, helper, repository), _RuleFactory._compilePatterns(desc.patterns, helper, repository));
				}
				return new BeginEndRule(desc.$vscodeTextmateLocation, desc.id, desc.name, desc.contentName, desc.begin, _RuleFactory._compileCaptures(desc.beginCaptures || desc.captures, helper, repository), desc.end, _RuleFactory._compileCaptures(desc.endCaptures || desc.captures, helper, repository), desc.applyEndPatternLast, _RuleFactory._compilePatterns(desc.patterns, helper, repository));
			});
		}
		return desc.id;
	}
	static _compileCaptures(captures, helper, repository) {
		let r$3 = [];
		if (captures) {
			let maximumCaptureId = 0;
			for (const captureId in captures) {
				if (captureId === "$vscodeTextmateLocation") {
					continue;
				}
				const numericCaptureId = parseInt(captureId, 10);
				if (numericCaptureId > maximumCaptureId) {
					maximumCaptureId = numericCaptureId;
				}
			}
			for (let i$2 = 0; i$2 <= maximumCaptureId; i$2++) {
				r$3[i$2] = null;
			}
			for (const captureId in captures) {
				if (captureId === "$vscodeTextmateLocation") {
					continue;
				}
				const numericCaptureId = parseInt(captureId, 10);
				let retokenizeCapturedWithRuleId = 0;
				if (captures[captureId].patterns) {
					retokenizeCapturedWithRuleId = _RuleFactory.getCompiledRuleId(captures[captureId], helper, repository);
				}
				r$3[numericCaptureId] = _RuleFactory.createCaptureRule(helper, captures[captureId].$vscodeTextmateLocation, captures[captureId].name, captures[captureId].contentName, retokenizeCapturedWithRuleId);
			}
		}
		return r$3;
	}
	static _compilePatterns(patterns, helper, repository) {
		let r$3 = [];
		if (patterns) {
			for (let i$2 = 0, len = patterns.length; i$2 < len; i$2++) {
				const pattern = patterns[i$2];
				let ruleId = -1;
				if (pattern.include) {
					const reference = parseInclude(pattern.include);
					switch (reference.kind) {
						case 0:
						case 1:
							ruleId = _RuleFactory.getCompiledRuleId(repository[pattern.include], helper, repository);
							break;
						case 2:
							let localIncludedRule = repository[reference.ruleName];
							if (localIncludedRule) {
								ruleId = _RuleFactory.getCompiledRuleId(localIncludedRule, helper, repository);
							} else {}
							break;
						case 3:
						case 4:
							const externalGrammarName = reference.scopeName;
							const externalGrammarInclude = reference.kind === 4 ? reference.ruleName : null;
							const externalGrammar = helper.getExternalGrammar(externalGrammarName, repository);
							if (externalGrammar) {
								if (externalGrammarInclude) {
									let externalIncludedRule = externalGrammar.repository[externalGrammarInclude];
									if (externalIncludedRule) {
										ruleId = _RuleFactory.getCompiledRuleId(externalIncludedRule, helper, externalGrammar.repository);
									} else {}
								} else {
									ruleId = _RuleFactory.getCompiledRuleId(externalGrammar.repository.$self, helper, externalGrammar.repository);
								}
							} else {}
							break;
					}
				} else {
					ruleId = _RuleFactory.getCompiledRuleId(pattern, helper, repository);
				}
				if (ruleId !== -1) {
					const rule = helper.getRule(ruleId);
					let skipRule = false;
					if (rule instanceof IncludeOnlyRule || rule instanceof BeginEndRule || rule instanceof BeginWhileRule) {
						if (rule.hasMissingPatterns && rule.patterns.length === 0) {
							skipRule = true;
						}
					}
					if (skipRule) {
						continue;
					}
					r$3.push(ruleId);
				}
			}
		}
		return {
			patterns: r$3,
			hasMissingPatterns: (patterns ? patterns.length : 0) !== r$3.length
		};
	}
};
var RegExpSource = class _RegExpSource {
	source;
	ruleId;
	hasAnchor;
	hasBackReferences;
	_anchorCache;
	constructor(regExpSource, ruleId) {
		if (regExpSource && typeof regExpSource === "string") {
			const len = regExpSource.length;
			let lastPushedPos = 0;
			let output = [];
			let hasAnchor = false;
			for (let pos = 0; pos < len; pos++) {
				const ch = regExpSource.charAt(pos);
				if (ch === "\\") {
					if (pos + 1 < len) {
						const nextCh = regExpSource.charAt(pos + 1);
						if (nextCh === "z") {
							output.push(regExpSource.substring(lastPushedPos, pos));
							output.push("$(?!\\n)(?<!\\n)");
							lastPushedPos = pos + 2;
						} else if (nextCh === "A" || nextCh === "G") {
							hasAnchor = true;
						}
						pos++;
					}
				}
			}
			this.hasAnchor = hasAnchor;
			if (lastPushedPos === 0) {
				this.source = regExpSource;
			} else {
				output.push(regExpSource.substring(lastPushedPos, len));
				this.source = output.join("");
			}
		} else {
			this.hasAnchor = false;
			this.source = regExpSource;
		}
		if (this.hasAnchor) {
			this._anchorCache = this._buildAnchorCache();
		} else {
			this._anchorCache = null;
		}
		this.ruleId = ruleId;
		if (typeof this.source === "string") {
			this.hasBackReferences = HAS_BACK_REFERENCES.test(this.source);
		} else {
			this.hasBackReferences = false;
		}
	}
	clone() {
		return new _RegExpSource(this.source, this.ruleId);
	}
	setSource(newSource) {
		if (this.source === newSource) {
			return;
		}
		this.source = newSource;
		if (this.hasAnchor) {
			this._anchorCache = this._buildAnchorCache();
		}
	}
	resolveBackReferences(lineText, captureIndices) {
		if (typeof this.source !== "string") {
			throw new Error("This method should only be called if the source is a string");
		}
		let capturedValues = captureIndices.map((capture) => {
			return lineText.substring(capture.start, capture.end);
		});
		BACK_REFERENCING_END.lastIndex = 0;
		return this.source.replace(BACK_REFERENCING_END, (match, g1) => {
			return escapeRegExpCharacters(capturedValues[parseInt(g1, 10)] || "");
		});
	}
	_buildAnchorCache() {
		if (typeof this.source !== "string") {
			throw new Error("This method should only be called if the source is a string");
		}
		let A0_G0_result = [];
		let A0_G1_result = [];
		let A1_G0_result = [];
		let A1_G1_result = [];
		let pos, len, ch, nextCh;
		for (pos = 0, len = this.source.length; pos < len; pos++) {
			ch = this.source.charAt(pos);
			A0_G0_result[pos] = ch;
			A0_G1_result[pos] = ch;
			A1_G0_result[pos] = ch;
			A1_G1_result[pos] = ch;
			if (ch === "\\") {
				if (pos + 1 < len) {
					nextCh = this.source.charAt(pos + 1);
					if (nextCh === "A") {
						A0_G0_result[pos + 1] = "￿";
						A0_G1_result[pos + 1] = "￿";
						A1_G0_result[pos + 1] = "A";
						A1_G1_result[pos + 1] = "A";
					} else if (nextCh === "G") {
						A0_G0_result[pos + 1] = "￿";
						A0_G1_result[pos + 1] = "G";
						A1_G0_result[pos + 1] = "￿";
						A1_G1_result[pos + 1] = "G";
					} else {
						A0_G0_result[pos + 1] = nextCh;
						A0_G1_result[pos + 1] = nextCh;
						A1_G0_result[pos + 1] = nextCh;
						A1_G1_result[pos + 1] = nextCh;
					}
					pos++;
				}
			}
		}
		return {
			A0_G0: A0_G0_result.join(""),
			A0_G1: A0_G1_result.join(""),
			A1_G0: A1_G0_result.join(""),
			A1_G1: A1_G1_result.join("")
		};
	}
	resolveAnchors(allowA, allowG) {
		if (!this.hasAnchor || !this._anchorCache || typeof this.source !== "string") {
			return this.source;
		}
		if (allowA) {
			if (allowG) {
				return this._anchorCache.A1_G1;
			} else {
				return this._anchorCache.A1_G0;
			}
		} else {
			if (allowG) {
				return this._anchorCache.A0_G1;
			} else {
				return this._anchorCache.A0_G0;
			}
		}
	}
};
var RegExpSourceList = class {
	_items;
	_hasAnchors;
	_cached;
	_anchorCache;
	constructor() {
		this._items = [];
		this._hasAnchors = false;
		this._cached = null;
		this._anchorCache = {
			A0_G0: null,
			A0_G1: null,
			A1_G0: null,
			A1_G1: null
		};
	}
	dispose() {
		this._disposeCaches();
	}
	_disposeCaches() {
		if (this._cached) {
			this._cached.dispose();
			this._cached = null;
		}
		if (this._anchorCache.A0_G0) {
			this._anchorCache.A0_G0.dispose();
			this._anchorCache.A0_G0 = null;
		}
		if (this._anchorCache.A0_G1) {
			this._anchorCache.A0_G1.dispose();
			this._anchorCache.A0_G1 = null;
		}
		if (this._anchorCache.A1_G0) {
			this._anchorCache.A1_G0.dispose();
			this._anchorCache.A1_G0 = null;
		}
		if (this._anchorCache.A1_G1) {
			this._anchorCache.A1_G1.dispose();
			this._anchorCache.A1_G1 = null;
		}
	}
	push(item) {
		this._items.push(item);
		this._hasAnchors = this._hasAnchors || item.hasAnchor;
	}
	unshift(item) {
		this._items.unshift(item);
		this._hasAnchors = this._hasAnchors || item.hasAnchor;
	}
	length() {
		return this._items.length;
	}
	setSource(index, newSource) {
		if (this._items[index].source !== newSource) {
			this._disposeCaches();
			this._items[index].setSource(newSource);
		}
	}
	compile(onigLib) {
		if (!this._cached) {
			let regExps = this._items.map((e) => e.source);
			this._cached = new CompiledRule(onigLib, regExps, this._items.map((e) => e.ruleId));
		}
		return this._cached;
	}
	compileAG(onigLib, allowA, allowG) {
		if (!this._hasAnchors) {
			return this.compile(onigLib);
		} else {
			if (allowA) {
				if (allowG) {
					if (!this._anchorCache.A1_G1) {
						this._anchorCache.A1_G1 = this._resolveAnchors(onigLib, allowA, allowG);
					}
					return this._anchorCache.A1_G1;
				} else {
					if (!this._anchorCache.A1_G0) {
						this._anchorCache.A1_G0 = this._resolveAnchors(onigLib, allowA, allowG);
					}
					return this._anchorCache.A1_G0;
				}
			} else {
				if (allowG) {
					if (!this._anchorCache.A0_G1) {
						this._anchorCache.A0_G1 = this._resolveAnchors(onigLib, allowA, allowG);
					}
					return this._anchorCache.A0_G1;
				} else {
					if (!this._anchorCache.A0_G0) {
						this._anchorCache.A0_G0 = this._resolveAnchors(onigLib, allowA, allowG);
					}
					return this._anchorCache.A0_G0;
				}
			}
		}
	}
	_resolveAnchors(onigLib, allowA, allowG) {
		let regExps = this._items.map((e) => e.resolveAnchors(allowA, allowG));
		return new CompiledRule(onigLib, regExps, this._items.map((e) => e.ruleId));
	}
};
var CompiledRule = class {
	constructor(onigLib, regExps, rules) {
		this.regExps = regExps;
		this.rules = rules;
		this.scanner = onigLib.createOnigScanner(regExps);
	}
	scanner;
	dispose() {
		if (typeof this.scanner.dispose === "function") {
			this.scanner.dispose();
		}
	}
	toString() {
		const r$3 = [];
		for (let i$2 = 0, len = this.rules.length; i$2 < len; i$2++) {
			r$3.push("   - " + this.rules[i$2] + ": " + this.regExps[i$2]);
		}
		return r$3.join("\n");
	}
	findNextMatchSync(string, startPosition, options) {
		const result = this.scanner.findNextMatchSync(string, startPosition, options);
		if (!result) {
			return null;
		}
		return {
			ruleId: this.rules[result.index],
			captureIndices: result.captureIndices
		};
	}
};
var BasicScopeAttributes = class {
	constructor(languageId, tokenType) {
		this.languageId = languageId;
		this.tokenType = tokenType;
	}
};
var BasicScopeAttributesProvider = class _BasicScopeAttributesProvider {
	_defaultAttributes;
	_embeddedLanguagesMatcher;
	constructor(initialLanguageId, embeddedLanguages) {
		this._defaultAttributes = new BasicScopeAttributes(initialLanguageId, 8);
		this._embeddedLanguagesMatcher = new ScopeMatcher(Object.entries(embeddedLanguages || {}));
	}
	getDefaultAttributes() {
		return this._defaultAttributes;
	}
	getBasicScopeAttributes(scopeName) {
		if (scopeName === null) {
			return _BasicScopeAttributesProvider._NULL_SCOPE_METADATA;
		}
		return this._getBasicScopeAttributes.get(scopeName);
	}
	static _NULL_SCOPE_METADATA = new BasicScopeAttributes(0, 0);
	_getBasicScopeAttributes = new CachedFn((scopeName) => {
		const languageId = this._scopeToLanguage(scopeName);
		const standardTokenType = this._toStandardTokenType(scopeName);
		return new BasicScopeAttributes(languageId, standardTokenType);
	});
	/**
	* Given a produced TM scope, return the language that token describes or null if unknown.
	* e.g. source.html => html, source.css.embedded.html => css, punctuation.definition.tag.html => null
	*/
	_scopeToLanguage(scope) {
		return this._embeddedLanguagesMatcher.match(scope) || 0;
	}
	_toStandardTokenType(scopeName) {
		const m$2 = scopeName.match(_BasicScopeAttributesProvider.STANDARD_TOKEN_TYPE_REGEXP);
		if (!m$2) {
			return 8;
		}
		switch (m$2[1]) {
			case "comment": return 1;
			case "string": return 2;
			case "regex": return 3;
			case "meta.embedded": return 0;
		}
		throw new Error("Unexpected match for standard token type!");
	}
	static STANDARD_TOKEN_TYPE_REGEXP = /\b(comment|string|regex|meta\.embedded)\b/;
};
var ScopeMatcher = class {
	values;
	scopesRegExp;
	constructor(values) {
		if (values.length === 0) {
			this.values = null;
			this.scopesRegExp = null;
		} else {
			this.values = new Map(values);
			const escapedScopes = values.map(([scopeName, value]) => escapeRegExpCharacters(scopeName));
			escapedScopes.sort();
			escapedScopes.reverse();
			this.scopesRegExp = new RegExp(`^((${escapedScopes.join(")|(")}))($|\\.)`, "");
		}
	}
	match(scope) {
		if (!this.scopesRegExp) {
			return void 0;
		}
		const m$2 = scope.match(this.scopesRegExp);
		if (!m$2) {
			return void 0;
		}
		return this.values.get(m$2[1]);
	}
};
var DebugFlags = { InDebugMode: typeof process !== "undefined" && !!process.env["VSCODE_TEXTMATE_DEBUG"] };
var UseOnigurumaFindOptions = false;
var TokenizeStringResult = class {
	constructor(stack, stoppedEarly) {
		this.stack = stack;
		this.stoppedEarly = stoppedEarly;
	}
};
function _tokenizeString(grammar, lineText, isFirstLine, linePos, stack, lineTokens, checkWhileConditions, timeLimit) {
	const lineLength = lineText.content.length;
	let STOP = false;
	let anchorPosition = -1;
	if (checkWhileConditions) {
		const whileCheckResult = _checkWhileConditions(grammar, lineText, isFirstLine, linePos, stack, lineTokens);
		stack = whileCheckResult.stack;
		linePos = whileCheckResult.linePos;
		isFirstLine = whileCheckResult.isFirstLine;
		anchorPosition = whileCheckResult.anchorPosition;
	}
	const startTime = Date.now();
	while (!STOP) {
		if (timeLimit !== 0) {
			const elapsedTime = Date.now() - startTime;
			if (elapsedTime > timeLimit) {
				return new TokenizeStringResult(stack, true);
			}
		}
		scanNext();
	}
	return new TokenizeStringResult(stack, false);
	function scanNext() {
		if (false) {
			console.log("");
			console.log(`@@scanNext ${linePos}: |${lineText.content.substr(linePos).replace(/\n$/, "\\n")}|`);
		}
		const r$3 = matchRuleOrInjections(grammar, lineText, isFirstLine, linePos, stack, anchorPosition);
		if (!r$3) {
			lineTokens.produce(stack, lineLength);
			STOP = true;
			return;
		}
		const captureIndices = r$3.captureIndices;
		const matchedRuleId = r$3.matchedRuleId;
		const hasAdvanced = captureIndices && captureIndices.length > 0 ? captureIndices[0].end > linePos : false;
		if (matchedRuleId === endRuleId) {
			const poppedRule = stack.getRule(grammar);
			if (false) {
				console.log("  popping " + poppedRule.debugName + " - " + poppedRule.debugEndRegExp);
			}
			lineTokens.produce(stack, captureIndices[0].start);
			stack = stack.withContentNameScopesList(stack.nameScopesList);
			handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, poppedRule.endCaptures, captureIndices);
			lineTokens.produce(stack, captureIndices[0].end);
			const popped = stack;
			stack = stack.parent;
			anchorPosition = popped.getAnchorPos();
			if (!hasAdvanced && popped.getEnterPos() === linePos) {
				if (false) {
					console.error("[1] - Grammar is in an endless loop - Grammar pushed & popped a rule without advancing");
				}
				stack = popped;
				lineTokens.produce(stack, lineLength);
				STOP = true;
				return;
			}
		} else {
			const _rule = grammar.getRule(matchedRuleId);
			lineTokens.produce(stack, captureIndices[0].start);
			const beforePush = stack;
			const scopeName = _rule.getName(lineText.content, captureIndices);
			const nameScopesList = stack.contentNameScopesList.pushAttributed(scopeName, grammar);
			stack = stack.push(matchedRuleId, linePos, anchorPosition, captureIndices[0].end === lineLength, null, nameScopesList, nameScopesList);
			if (_rule instanceof BeginEndRule) {
				const pushedRule = _rule;
				if (false) {
					console.log("  pushing " + pushedRule.debugName + " - " + pushedRule.debugBeginRegExp);
				}
				handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, pushedRule.beginCaptures, captureIndices);
				lineTokens.produce(stack, captureIndices[0].end);
				anchorPosition = captureIndices[0].end;
				const contentName = pushedRule.getContentName(lineText.content, captureIndices);
				const contentNameScopesList = nameScopesList.pushAttributed(contentName, grammar);
				stack = stack.withContentNameScopesList(contentNameScopesList);
				if (pushedRule.endHasBackReferences) {
					stack = stack.withEndRule(pushedRule.getEndWithResolvedBackReferences(lineText.content, captureIndices));
				}
				if (!hasAdvanced && beforePush.hasSameRuleAs(stack)) {
					if (false) {
						console.error("[2] - Grammar is in an endless loop - Grammar pushed the same rule without advancing");
					}
					stack = stack.pop();
					lineTokens.produce(stack, lineLength);
					STOP = true;
					return;
				}
			} else if (_rule instanceof BeginWhileRule) {
				const pushedRule = _rule;
				if (false) {
					console.log("  pushing " + pushedRule.debugName);
				}
				handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, pushedRule.beginCaptures, captureIndices);
				lineTokens.produce(stack, captureIndices[0].end);
				anchorPosition = captureIndices[0].end;
				const contentName = pushedRule.getContentName(lineText.content, captureIndices);
				const contentNameScopesList = nameScopesList.pushAttributed(contentName, grammar);
				stack = stack.withContentNameScopesList(contentNameScopesList);
				if (pushedRule.whileHasBackReferences) {
					stack = stack.withEndRule(pushedRule.getWhileWithResolvedBackReferences(lineText.content, captureIndices));
				}
				if (!hasAdvanced && beforePush.hasSameRuleAs(stack)) {
					if (false) {
						console.error("[3] - Grammar is in an endless loop - Grammar pushed the same rule without advancing");
					}
					stack = stack.pop();
					lineTokens.produce(stack, lineLength);
					STOP = true;
					return;
				}
			} else {
				const matchingRule = _rule;
				if (false) {
					console.log("  matched " + matchingRule.debugName + " - " + matchingRule.debugMatchRegExp);
				}
				handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, matchingRule.captures, captureIndices);
				lineTokens.produce(stack, captureIndices[0].end);
				stack = stack.pop();
				if (!hasAdvanced) {
					if (false) {
						console.error("[4] - Grammar is in an endless loop - Grammar is not advancing, nor is it pushing/popping");
					}
					stack = stack.safePop();
					lineTokens.produce(stack, lineLength);
					STOP = true;
					return;
				}
			}
		}
		if (captureIndices[0].end > linePos) {
			linePos = captureIndices[0].end;
			isFirstLine = false;
		}
	}
}
function _checkWhileConditions(grammar, lineText, isFirstLine, linePos, stack, lineTokens) {
	let anchorPosition = stack.beginRuleCapturedEOL ? 0 : -1;
	const whileRules = [];
	for (let node = stack; node; node = node.pop()) {
		const nodeRule = node.getRule(grammar);
		if (nodeRule instanceof BeginWhileRule) {
			whileRules.push({
				rule: nodeRule,
				stack: node
			});
		}
	}
	for (let whileRule = whileRules.pop(); whileRule; whileRule = whileRules.pop()) {
		const { ruleScanner, findOptions } = prepareRuleWhileSearch(whileRule.rule, grammar, whileRule.stack.endRule, isFirstLine, linePos === anchorPosition);
		const r$3 = ruleScanner.findNextMatchSync(lineText, linePos, findOptions);
		if (false) {
			console.log("  scanning for while rule");
			console.log(ruleScanner.toString());
		}
		if (r$3) {
			const matchedRuleId = r$3.ruleId;
			if (matchedRuleId !== whileRuleId) {
				stack = whileRule.stack.pop();
				break;
			}
			if (r$3.captureIndices && r$3.captureIndices.length) {
				lineTokens.produce(whileRule.stack, r$3.captureIndices[0].start);
				handleCaptures(grammar, lineText, isFirstLine, whileRule.stack, lineTokens, whileRule.rule.whileCaptures, r$3.captureIndices);
				lineTokens.produce(whileRule.stack, r$3.captureIndices[0].end);
				anchorPosition = r$3.captureIndices[0].end;
				if (r$3.captureIndices[0].end > linePos) {
					linePos = r$3.captureIndices[0].end;
					isFirstLine = false;
				}
			}
		} else {
			if (false) {
				console.log("  popping " + whileRule.rule.debugName + " - " + whileRule.rule.debugWhileRegExp);
			}
			stack = whileRule.stack.pop();
			break;
		}
	}
	return {
		stack,
		linePos,
		anchorPosition,
		isFirstLine
	};
}
function matchRuleOrInjections(grammar, lineText, isFirstLine, linePos, stack, anchorPosition) {
	const matchResult = matchRule(grammar, lineText, isFirstLine, linePos, stack, anchorPosition);
	const injections = grammar.getInjections();
	if (injections.length === 0) {
		return matchResult;
	}
	const injectionResult = matchInjections(injections, grammar, lineText, isFirstLine, linePos, stack, anchorPosition);
	if (!injectionResult) {
		return matchResult;
	}
	if (!matchResult) {
		return injectionResult;
	}
	const matchResultScore = matchResult.captureIndices[0].start;
	const injectionResultScore = injectionResult.captureIndices[0].start;
	if (injectionResultScore < matchResultScore || injectionResult.priorityMatch && injectionResultScore === matchResultScore) {
		return injectionResult;
	}
	return matchResult;
}
function matchRule(grammar, lineText, isFirstLine, linePos, stack, anchorPosition) {
	const rule = stack.getRule(grammar);
	const { ruleScanner, findOptions } = prepareRuleSearch(rule, grammar, stack.endRule, isFirstLine, linePos === anchorPosition);
	const r$3 = ruleScanner.findNextMatchSync(lineText, linePos, findOptions);
	if (r$3) {
		return {
			captureIndices: r$3.captureIndices,
			matchedRuleId: r$3.ruleId
		};
	}
	return null;
}
function matchInjections(injections, grammar, lineText, isFirstLine, linePos, stack, anchorPosition) {
	let bestMatchRating = Number.MAX_VALUE;
	let bestMatchCaptureIndices = null;
	let bestMatchRuleId;
	let bestMatchResultPriority = 0;
	const scopes = stack.contentNameScopesList.getScopeNames();
	for (let i$2 = 0, len = injections.length; i$2 < len; i$2++) {
		const injection = injections[i$2];
		if (!injection.matcher(scopes)) {
			continue;
		}
		const rule = grammar.getRule(injection.ruleId);
		const { ruleScanner, findOptions } = prepareRuleSearch(rule, grammar, null, isFirstLine, linePos === anchorPosition);
		const matchResult = ruleScanner.findNextMatchSync(lineText, linePos, findOptions);
		if (!matchResult) {
			continue;
		}
		if (false) {
			console.log(`  matched injection: ${injection.debugSelector}`);
			console.log(ruleScanner.toString());
		}
		const matchRating = matchResult.captureIndices[0].start;
		if (matchRating >= bestMatchRating) {
			continue;
		}
		bestMatchRating = matchRating;
		bestMatchCaptureIndices = matchResult.captureIndices;
		bestMatchRuleId = matchResult.ruleId;
		bestMatchResultPriority = injection.priority;
		if (bestMatchRating === linePos) {
			break;
		}
	}
	if (bestMatchCaptureIndices) {
		return {
			priorityMatch: bestMatchResultPriority === -1,
			captureIndices: bestMatchCaptureIndices,
			matchedRuleId: bestMatchRuleId
		};
	}
	return null;
}
function prepareRuleSearch(rule, grammar, endRegexSource, allowA, allowG) {
	if (UseOnigurumaFindOptions) {
		const ruleScanner2 = rule.compile(grammar, endRegexSource);
		const findOptions = getFindOptions(allowA, allowG);
		return {
			ruleScanner: ruleScanner2,
			findOptions
		};
	}
	const ruleScanner = rule.compileAG(grammar, endRegexSource, allowA, allowG);
	return {
		ruleScanner,
		findOptions: 0
	};
}
function prepareRuleWhileSearch(rule, grammar, endRegexSource, allowA, allowG) {
	if (UseOnigurumaFindOptions) {
		const ruleScanner2 = rule.compileWhile(grammar, endRegexSource);
		const findOptions = getFindOptions(allowA, allowG);
		return {
			ruleScanner: ruleScanner2,
			findOptions
		};
	}
	const ruleScanner = rule.compileWhileAG(grammar, endRegexSource, allowA, allowG);
	return {
		ruleScanner,
		findOptions: 0
	};
}
function getFindOptions(allowA, allowG) {
	let options = 0;
	if (!allowA) {
		options |= 1;
	}
	if (!allowG) {
		options |= 4;
	}
	return options;
}
function handleCaptures(grammar, lineText, isFirstLine, stack, lineTokens, captures, captureIndices) {
	if (captures.length === 0) {
		return;
	}
	const lineTextContent = lineText.content;
	const len = Math.min(captures.length, captureIndices.length);
	const localStack = [];
	const maxEnd = captureIndices[0].end;
	for (let i$2 = 0; i$2 < len; i$2++) {
		const captureRule = captures[i$2];
		if (captureRule === null) {
			continue;
		}
		const captureIndex = captureIndices[i$2];
		if (captureIndex.length === 0) {
			continue;
		}
		if (captureIndex.start > maxEnd) {
			break;
		}
		while (localStack.length > 0 && localStack[localStack.length - 1].endPos <= captureIndex.start) {
			lineTokens.produceFromScopes(localStack[localStack.length - 1].scopes, localStack[localStack.length - 1].endPos);
			localStack.pop();
		}
		if (localStack.length > 0) {
			lineTokens.produceFromScopes(localStack[localStack.length - 1].scopes, captureIndex.start);
		} else {
			lineTokens.produce(stack, captureIndex.start);
		}
		if (captureRule.retokenizeCapturedWithRuleId) {
			const scopeName = captureRule.getName(lineTextContent, captureIndices);
			const nameScopesList = stack.contentNameScopesList.pushAttributed(scopeName, grammar);
			const contentName = captureRule.getContentName(lineTextContent, captureIndices);
			const contentNameScopesList = nameScopesList.pushAttributed(contentName, grammar);
			const stackClone = stack.push(captureRule.retokenizeCapturedWithRuleId, captureIndex.start, -1, false, null, nameScopesList, contentNameScopesList);
			const onigSubStr = grammar.createOnigString(lineTextContent.substring(0, captureIndex.end));
			_tokenizeString(grammar, onigSubStr, isFirstLine && captureIndex.start === 0, captureIndex.start, stackClone, lineTokens, false, 0);
			disposeOnigString(onigSubStr);
			continue;
		}
		const captureRuleScopeName = captureRule.getName(lineTextContent, captureIndices);
		if (captureRuleScopeName !== null) {
			const base = localStack.length > 0 ? localStack[localStack.length - 1].scopes : stack.contentNameScopesList;
			const captureRuleScopesList = base.pushAttributed(captureRuleScopeName, grammar);
			localStack.push(new LocalStackElement(captureRuleScopesList, captureIndex.end));
		}
	}
	while (localStack.length > 0) {
		lineTokens.produceFromScopes(localStack[localStack.length - 1].scopes, localStack[localStack.length - 1].endPos);
		localStack.pop();
	}
}
var LocalStackElement = class {
	scopes;
	endPos;
	constructor(scopes, endPos) {
		this.scopes = scopes;
		this.endPos = endPos;
	}
};
function createGrammar(scopeName, grammar, initialLanguage, embeddedLanguages, tokenTypes, balancedBracketSelectors, grammarRepository, onigLib) {
	return new Grammar(scopeName, grammar, initialLanguage, embeddedLanguages, tokenTypes, balancedBracketSelectors, grammarRepository, onigLib);
}
function collectInjections(result, selector, rule, ruleFactoryHelper, grammar) {
	const matchers$1 = createMatchers(selector, nameMatcher);
	const ruleId = RuleFactory.getCompiledRuleId(rule, ruleFactoryHelper, grammar.repository);
	for (const matcher of matchers$1) {
		result.push({
			debugSelector: selector,
			matcher: matcher.matcher,
			ruleId,
			grammar,
			priority: matcher.priority
		});
	}
}
function nameMatcher(identifers, scopes) {
	if (scopes.length < identifers.length) {
		return false;
	}
	let lastIndex = 0;
	return identifers.every((identifier) => {
		for (let i$2 = lastIndex; i$2 < scopes.length; i$2++) {
			if (scopesAreMatching(scopes[i$2], identifier)) {
				lastIndex = i$2 + 1;
				return true;
			}
		}
		return false;
	});
}
function scopesAreMatching(thisScopeName, scopeName) {
	if (!thisScopeName) {
		return false;
	}
	if (thisScopeName === scopeName) {
		return true;
	}
	const len = scopeName.length;
	return thisScopeName.length > len && thisScopeName.substr(0, len) === scopeName && thisScopeName[len] === ".";
}
var Grammar = class {
	constructor(_rootScopeName, grammar, initialLanguage, embeddedLanguages, tokenTypes, balancedBracketSelectors, grammarRepository, _onigLib) {
		this._rootScopeName = _rootScopeName;
		this.balancedBracketSelectors = balancedBracketSelectors;
		this._onigLib = _onigLib;
		this._basicScopeAttributesProvider = new BasicScopeAttributesProvider(initialLanguage, embeddedLanguages);
		this._rootId = -1;
		this._lastRuleId = 0;
		this._ruleId2desc = [null];
		this._includedGrammars = {};
		this._grammarRepository = grammarRepository;
		this._grammar = initGrammar(grammar, null);
		this._injections = null;
		this._tokenTypeMatchers = [];
		if (tokenTypes) {
			for (const selector of Object.keys(tokenTypes)) {
				const matchers$1 = createMatchers(selector, nameMatcher);
				for (const matcher of matchers$1) {
					this._tokenTypeMatchers.push({
						matcher: matcher.matcher,
						type: tokenTypes[selector]
					});
				}
			}
		}
	}
	_rootId;
	_lastRuleId;
	_ruleId2desc;
	_includedGrammars;
	_grammarRepository;
	_grammar;
	_injections;
	_basicScopeAttributesProvider;
	_tokenTypeMatchers;
	get themeProvider() {
		return this._grammarRepository;
	}
	dispose() {
		for (const rule of this._ruleId2desc) {
			if (rule) {
				rule.dispose();
			}
		}
	}
	createOnigScanner(sources) {
		return this._onigLib.createOnigScanner(sources);
	}
	createOnigString(sources) {
		return this._onigLib.createOnigString(sources);
	}
	getMetadataForScope(scope) {
		return this._basicScopeAttributesProvider.getBasicScopeAttributes(scope);
	}
	_collectInjections() {
		const grammarRepository = {
			lookup: (scopeName2) => {
				if (scopeName2 === this._rootScopeName) {
					return this._grammar;
				}
				return this.getExternalGrammar(scopeName2);
			},
			injections: (scopeName2) => {
				return this._grammarRepository.injections(scopeName2);
			}
		};
		const result = [];
		const scopeName = this._rootScopeName;
		const grammar = grammarRepository.lookup(scopeName);
		if (grammar) {
			const rawInjections = grammar.injections;
			if (rawInjections) {
				for (let expression in rawInjections) {
					collectInjections(result, expression, rawInjections[expression], this, grammar);
				}
			}
			const injectionScopeNames = this._grammarRepository.injections(scopeName);
			if (injectionScopeNames) {
				injectionScopeNames.forEach((injectionScopeName) => {
					const injectionGrammar = this.getExternalGrammar(injectionScopeName);
					if (injectionGrammar) {
						const selector = injectionGrammar.injectionSelector;
						if (selector) {
							collectInjections(result, selector, injectionGrammar, this, injectionGrammar);
						}
					}
				});
			}
		}
		result.sort((i1, i2) => i1.priority - i2.priority);
		return result;
	}
	getInjections() {
		if (this._injections === null) {
			this._injections = this._collectInjections();
		}
		return this._injections;
	}
	registerRule(factory) {
		const id = ++this._lastRuleId;
		const result = factory(ruleIdFromNumber(id));
		this._ruleId2desc[id] = result;
		return result;
	}
	getRule(ruleId) {
		return this._ruleId2desc[ruleIdToNumber(ruleId)];
	}
	getExternalGrammar(scopeName, repository) {
		if (this._includedGrammars[scopeName]) {
			return this._includedGrammars[scopeName];
		} else if (this._grammarRepository) {
			const rawIncludedGrammar = this._grammarRepository.lookup(scopeName);
			if (rawIncludedGrammar) {
				this._includedGrammars[scopeName] = initGrammar(rawIncludedGrammar, repository && repository.$base);
				return this._includedGrammars[scopeName];
			}
		}
		return void 0;
	}
	tokenizeLine(lineText, prevState, timeLimit = 0) {
		const r$3 = this._tokenize(lineText, prevState, false, timeLimit);
		return {
			tokens: r$3.lineTokens.getResult(r$3.ruleStack, r$3.lineLength),
			ruleStack: r$3.ruleStack,
			stoppedEarly: r$3.stoppedEarly
		};
	}
	tokenizeLine2(lineText, prevState, timeLimit = 0) {
		const r$3 = this._tokenize(lineText, prevState, true, timeLimit);
		return {
			tokens: r$3.lineTokens.getBinaryResult(r$3.ruleStack, r$3.lineLength),
			ruleStack: r$3.ruleStack,
			stoppedEarly: r$3.stoppedEarly
		};
	}
	_tokenize(lineText, prevState, emitBinaryTokens, timeLimit) {
		if (this._rootId === -1) {
			this._rootId = RuleFactory.getCompiledRuleId(this._grammar.repository.$self, this, this._grammar.repository);
			this.getInjections();
		}
		let isFirstLine;
		if (!prevState || prevState === StateStackImpl.NULL) {
			isFirstLine = true;
			const rawDefaultMetadata = this._basicScopeAttributesProvider.getDefaultAttributes();
			const defaultStyle = this.themeProvider.getDefaults();
			const defaultMetadata = EncodedTokenMetadata.set(0, rawDefaultMetadata.languageId, rawDefaultMetadata.tokenType, null, defaultStyle.fontStyle, defaultStyle.foregroundId, defaultStyle.backgroundId);
			const rootScopeName = this.getRule(this._rootId).getName(null, null);
			let scopeList;
			if (rootScopeName) {
				scopeList = AttributedScopeStack.createRootAndLookUpScopeName(rootScopeName, defaultMetadata, this);
			} else {
				scopeList = AttributedScopeStack.createRoot("unknown", defaultMetadata);
			}
			prevState = new StateStackImpl(null, this._rootId, -1, -1, false, null, scopeList, scopeList);
		} else {
			isFirstLine = false;
			prevState.reset();
		}
		lineText = lineText + "\n";
		const onigLineText = this.createOnigString(lineText);
		const lineLength = onigLineText.content.length;
		const lineTokens = new LineTokens(emitBinaryTokens, lineText, this._tokenTypeMatchers, this.balancedBracketSelectors);
		const r$3 = _tokenizeString(this, onigLineText, isFirstLine, 0, prevState, lineTokens, true, timeLimit);
		disposeOnigString(onigLineText);
		return {
			lineLength,
			lineTokens,
			ruleStack: r$3.stack,
			stoppedEarly: r$3.stoppedEarly
		};
	}
};
function initGrammar(grammar, base) {
	grammar = clone(grammar);
	grammar.repository = grammar.repository || {};
	grammar.repository.$self = {
		$vscodeTextmateLocation: grammar.$vscodeTextmateLocation,
		patterns: grammar.patterns,
		name: grammar.scopeName
	};
	grammar.repository.$base = base || grammar.repository.$self;
	return grammar;
}
var AttributedScopeStack = class _AttributedScopeStack {
	/**
	* Invariant:
	* ```
	* if (parent && !scopePath.extends(parent.scopePath)) {
	* 	throw new Error();
	* }
	* ```
	*/
	constructor(parent, scopePath, tokenAttributes) {
		this.parent = parent;
		this.scopePath = scopePath;
		this.tokenAttributes = tokenAttributes;
	}
	static fromExtension(namesScopeList, contentNameScopesList) {
		let current = namesScopeList;
		let scopeNames = namesScopeList?.scopePath ?? null;
		for (const frame of contentNameScopesList) {
			scopeNames = ScopeStack.push(scopeNames, frame.scopeNames);
			current = new _AttributedScopeStack(current, scopeNames, frame.encodedTokenAttributes);
		}
		return current;
	}
	static createRoot(scopeName, tokenAttributes) {
		return new _AttributedScopeStack(null, new ScopeStack(null, scopeName), tokenAttributes);
	}
	static createRootAndLookUpScopeName(scopeName, tokenAttributes, grammar) {
		const rawRootMetadata = grammar.getMetadataForScope(scopeName);
		const scopePath = new ScopeStack(null, scopeName);
		const rootStyle = grammar.themeProvider.themeMatch(scopePath);
		const resolvedTokenAttributes = _AttributedScopeStack.mergeAttributes(tokenAttributes, rawRootMetadata, rootStyle);
		return new _AttributedScopeStack(null, scopePath, resolvedTokenAttributes);
	}
	get scopeName() {
		return this.scopePath.scopeName;
	}
	toString() {
		return this.getScopeNames().join(" ");
	}
	equals(other) {
		return _AttributedScopeStack.equals(this, other);
	}
	static equals(a$1, b$2) {
		do {
			if (a$1 === b$2) {
				return true;
			}
			if (!a$1 && !b$2) {
				return true;
			}
			if (!a$1 || !b$2) {
				return false;
			}
			if (a$1.scopeName !== b$2.scopeName || a$1.tokenAttributes !== b$2.tokenAttributes) {
				return false;
			}
			a$1 = a$1.parent;
			b$2 = b$2.parent;
		} while (true);
	}
	static mergeAttributes(existingTokenAttributes, basicScopeAttributes, styleAttributes) {
		let fontStyle = -1;
		let foreground = 0;
		let background = 0;
		if (styleAttributes !== null) {
			fontStyle = styleAttributes.fontStyle;
			foreground = styleAttributes.foregroundId;
			background = styleAttributes.backgroundId;
		}
		return EncodedTokenMetadata.set(existingTokenAttributes, basicScopeAttributes.languageId, basicScopeAttributes.tokenType, null, fontStyle, foreground, background);
	}
	pushAttributed(scopePath, grammar) {
		if (scopePath === null) {
			return this;
		}
		if (scopePath.indexOf(" ") === -1) {
			return _AttributedScopeStack._pushAttributed(this, scopePath, grammar);
		}
		const scopes = scopePath.split(/ /g);
		let result = this;
		for (const scope of scopes) {
			result = _AttributedScopeStack._pushAttributed(result, scope, grammar);
		}
		return result;
	}
	static _pushAttributed(target, scopeName, grammar) {
		const rawMetadata = grammar.getMetadataForScope(scopeName);
		const newPath = target.scopePath.push(scopeName);
		const scopeThemeMatchResult = grammar.themeProvider.themeMatch(newPath);
		const metadata = _AttributedScopeStack.mergeAttributes(target.tokenAttributes, rawMetadata, scopeThemeMatchResult);
		return new _AttributedScopeStack(target, newPath, metadata);
	}
	getScopeNames() {
		return this.scopePath.getSegments();
	}
	getExtensionIfDefined(base) {
		const result = [];
		let self$1 = this;
		while (self$1 && self$1 !== base) {
			result.push({
				encodedTokenAttributes: self$1.tokenAttributes,
				scopeNames: self$1.scopePath.getExtensionIfDefined(self$1.parent?.scopePath ?? null)
			});
			self$1 = self$1.parent;
		}
		return self$1 === base ? result.reverse() : void 0;
	}
};
var StateStackImpl = class _StateStackImpl {
	/**
	* Invariant:
	* ```
	* if (contentNameScopesList !== nameScopesList && contentNameScopesList?.parent !== nameScopesList) {
	* 	throw new Error();
	* }
	* if (this.parent && !nameScopesList.extends(this.parent.contentNameScopesList)) {
	* 	throw new Error();
	* }
	* ```
	*/
	constructor(parent, ruleId, enterPos, anchorPos, beginRuleCapturedEOL, endRule, nameScopesList, contentNameScopesList) {
		this.parent = parent;
		this.ruleId = ruleId;
		this.beginRuleCapturedEOL = beginRuleCapturedEOL;
		this.endRule = endRule;
		this.nameScopesList = nameScopesList;
		this.contentNameScopesList = contentNameScopesList;
		this.depth = this.parent ? this.parent.depth + 1 : 1;
		this._enterPos = enterPos;
		this._anchorPos = anchorPos;
	}
	_stackElementBrand = void 0;
	static NULL = new _StateStackImpl(null, 0, 0, 0, false, null, null, null);
	/**
	* The position on the current line where this state was pushed.
	* This is relevant only while tokenizing a line, to detect endless loops.
	* Its value is meaningless across lines.
	*/
	_enterPos;
	/**
	* The captured anchor position when this stack element was pushed.
	* This is relevant only while tokenizing a line, to restore the anchor position when popping.
	* Its value is meaningless across lines.
	*/
	_anchorPos;
	/**
	* The depth of the stack.
	*/
	depth;
	equals(other) {
		if (other === null) {
			return false;
		}
		return _StateStackImpl._equals(this, other);
	}
	static _equals(a$1, b$2) {
		if (a$1 === b$2) {
			return true;
		}
		if (!this._structuralEquals(a$1, b$2)) {
			return false;
		}
		return AttributedScopeStack.equals(a$1.contentNameScopesList, b$2.contentNameScopesList);
	}
	/**
	* A structural equals check. Does not take into account `scopes`.
	*/
	static _structuralEquals(a$1, b$2) {
		do {
			if (a$1 === b$2) {
				return true;
			}
			if (!a$1 && !b$2) {
				return true;
			}
			if (!a$1 || !b$2) {
				return false;
			}
			if (a$1.depth !== b$2.depth || a$1.ruleId !== b$2.ruleId || a$1.endRule !== b$2.endRule) {
				return false;
			}
			a$1 = a$1.parent;
			b$2 = b$2.parent;
		} while (true);
	}
	clone() {
		return this;
	}
	static _reset(el) {
		while (el) {
			el._enterPos = -1;
			el._anchorPos = -1;
			el = el.parent;
		}
	}
	reset() {
		_StateStackImpl._reset(this);
	}
	pop() {
		return this.parent;
	}
	safePop() {
		if (this.parent) {
			return this.parent;
		}
		return this;
	}
	push(ruleId, enterPos, anchorPos, beginRuleCapturedEOL, endRule, nameScopesList, contentNameScopesList) {
		return new _StateStackImpl(this, ruleId, enterPos, anchorPos, beginRuleCapturedEOL, endRule, nameScopesList, contentNameScopesList);
	}
	getEnterPos() {
		return this._enterPos;
	}
	getAnchorPos() {
		return this._anchorPos;
	}
	getRule(grammar) {
		return grammar.getRule(this.ruleId);
	}
	toString() {
		const r$3 = [];
		this._writeString(r$3, 0);
		return "[" + r$3.join(",") + "]";
	}
	_writeString(res, outIndex) {
		if (this.parent) {
			outIndex = this.parent._writeString(res, outIndex);
		}
		res[outIndex++] = `(${this.ruleId}, ${this.nameScopesList?.toString()}, ${this.contentNameScopesList?.toString()})`;
		return outIndex;
	}
	withContentNameScopesList(contentNameScopeStack) {
		if (this.contentNameScopesList === contentNameScopeStack) {
			return this;
		}
		return this.parent.push(this.ruleId, this._enterPos, this._anchorPos, this.beginRuleCapturedEOL, this.endRule, this.nameScopesList, contentNameScopeStack);
	}
	withEndRule(endRule) {
		if (this.endRule === endRule) {
			return this;
		}
		return new _StateStackImpl(this.parent, this.ruleId, this._enterPos, this._anchorPos, this.beginRuleCapturedEOL, endRule, this.nameScopesList, this.contentNameScopesList);
	}
	hasSameRuleAs(other) {
		let el = this;
		while (el && el._enterPos === other._enterPos) {
			if (el.ruleId === other.ruleId) {
				return true;
			}
			el = el.parent;
		}
		return false;
	}
	toStateStackFrame() {
		return {
			ruleId: ruleIdToNumber(this.ruleId),
			beginRuleCapturedEOL: this.beginRuleCapturedEOL,
			endRule: this.endRule,
			nameScopesList: this.nameScopesList?.getExtensionIfDefined(this.parent?.nameScopesList ?? null) ?? [],
			contentNameScopesList: this.contentNameScopesList?.getExtensionIfDefined(this.nameScopesList) ?? []
		};
	}
	static pushFrame(self$1, frame) {
		const namesScopeList = AttributedScopeStack.fromExtension(self$1?.nameScopesList ?? null, frame.nameScopesList);
		return new _StateStackImpl(self$1, ruleIdFromNumber(frame.ruleId), frame.enterPos ?? -1, frame.anchorPos ?? -1, frame.beginRuleCapturedEOL, frame.endRule, namesScopeList, AttributedScopeStack.fromExtension(namesScopeList, frame.contentNameScopesList));
	}
};
var BalancedBracketSelectors = class {
	balancedBracketScopes;
	unbalancedBracketScopes;
	allowAny = false;
	constructor(balancedBracketScopes, unbalancedBracketScopes) {
		this.balancedBracketScopes = balancedBracketScopes.flatMap((selector) => {
			if (selector === "*") {
				this.allowAny = true;
				return [];
			}
			return createMatchers(selector, nameMatcher).map((m$2) => m$2.matcher);
		});
		this.unbalancedBracketScopes = unbalancedBracketScopes.flatMap((selector) => createMatchers(selector, nameMatcher).map((m$2) => m$2.matcher));
	}
	get matchesAlways() {
		return this.allowAny && this.unbalancedBracketScopes.length === 0;
	}
	get matchesNever() {
		return this.balancedBracketScopes.length === 0 && !this.allowAny;
	}
	match(scopes) {
		for (const excluder of this.unbalancedBracketScopes) {
			if (excluder(scopes)) {
				return false;
			}
		}
		for (const includer of this.balancedBracketScopes) {
			if (includer(scopes)) {
				return true;
			}
		}
		return this.allowAny;
	}
};
var LineTokens = class {
	constructor(emitBinaryTokens, lineText, tokenTypeOverrides, balancedBracketSelectors) {
		this.balancedBracketSelectors = balancedBracketSelectors;
		this._emitBinaryTokens = emitBinaryTokens;
		this._tokenTypeOverrides = tokenTypeOverrides;
		if (false) {
			this._lineText = lineText;
		} else {
			this._lineText = null;
		}
		this._tokens = [];
		this._binaryTokens = [];
		this._lastTokenEndIndex = 0;
	}
	_emitBinaryTokens;
	/**
	* defined only if `false`.
	*/
	_lineText;
	/**
	* used only if `_emitBinaryTokens` is false.
	*/
	_tokens;
	/**
	* used only if `_emitBinaryTokens` is true.
	*/
	_binaryTokens;
	_lastTokenEndIndex;
	_tokenTypeOverrides;
	produce(stack, endIndex) {
		this.produceFromScopes(stack.contentNameScopesList, endIndex);
	}
	produceFromScopes(scopesList, endIndex) {
		if (this._lastTokenEndIndex >= endIndex) {
			return;
		}
		if (this._emitBinaryTokens) {
			let metadata = scopesList?.tokenAttributes ?? 0;
			let containsBalancedBrackets = false;
			if (this.balancedBracketSelectors?.matchesAlways) {
				containsBalancedBrackets = true;
			}
			if (this._tokenTypeOverrides.length > 0 || this.balancedBracketSelectors && !this.balancedBracketSelectors.matchesAlways && !this.balancedBracketSelectors.matchesNever) {
				const scopes2 = scopesList?.getScopeNames() ?? [];
				for (const tokenType of this._tokenTypeOverrides) {
					if (tokenType.matcher(scopes2)) {
						metadata = EncodedTokenMetadata.set(metadata, 0, toOptionalTokenType(tokenType.type), null, -1, 0, 0);
					}
				}
				if (this.balancedBracketSelectors) {
					containsBalancedBrackets = this.balancedBracketSelectors.match(scopes2);
				}
			}
			if (containsBalancedBrackets) {
				metadata = EncodedTokenMetadata.set(metadata, 0, 8, containsBalancedBrackets, -1, 0, 0);
			}
			if (this._binaryTokens.length > 0 && this._binaryTokens[this._binaryTokens.length - 1] === metadata) {
				this._lastTokenEndIndex = endIndex;
				return;
			}
			this._binaryTokens.push(this._lastTokenEndIndex);
			this._binaryTokens.push(metadata);
			this._lastTokenEndIndex = endIndex;
			return;
		}
		const scopes = scopesList?.getScopeNames() ?? [];
		this._tokens.push({
			startIndex: this._lastTokenEndIndex,
			endIndex,
			scopes
		});
		this._lastTokenEndIndex = endIndex;
	}
	getResult(stack, lineLength) {
		if (this._tokens.length > 0 && this._tokens[this._tokens.length - 1].startIndex === lineLength - 1) {
			this._tokens.pop();
		}
		if (this._tokens.length === 0) {
			this._lastTokenEndIndex = -1;
			this.produce(stack, lineLength);
			this._tokens[this._tokens.length - 1].startIndex = 0;
		}
		return this._tokens;
	}
	getBinaryResult(stack, lineLength) {
		if (this._binaryTokens.length > 0 && this._binaryTokens[this._binaryTokens.length - 2] === lineLength - 1) {
			this._binaryTokens.pop();
			this._binaryTokens.pop();
		}
		if (this._binaryTokens.length === 0) {
			this._lastTokenEndIndex = -1;
			this.produce(stack, lineLength);
			this._binaryTokens[this._binaryTokens.length - 2] = 0;
		}
		const result = new Uint32Array(this._binaryTokens.length);
		for (let i$2 = 0, len = this._binaryTokens.length; i$2 < len; i$2++) {
			result[i$2] = this._binaryTokens[i$2];
		}
		return result;
	}
};
var SyncRegistry = class {
	constructor(theme, _onigLib) {
		this._onigLib = _onigLib;
		this._theme = theme;
	}
	_grammars = /* @__PURE__ */ new Map();
	_rawGrammars = /* @__PURE__ */ new Map();
	_injectionGrammars = /* @__PURE__ */ new Map();
	_theme;
	dispose() {
		for (const grammar of this._grammars.values()) {
			grammar.dispose();
		}
	}
	setTheme(theme) {
		this._theme = theme;
	}
	getColorMap() {
		return this._theme.getColorMap();
	}
	/**
	* Add `grammar` to registry and return a list of referenced scope names
	*/
	addGrammar(grammar, injectionScopeNames) {
		this._rawGrammars.set(grammar.scopeName, grammar);
		if (injectionScopeNames) {
			this._injectionGrammars.set(grammar.scopeName, injectionScopeNames);
		}
	}
	/**
	* Lookup a raw grammar.
	*/
	lookup(scopeName) {
		return this._rawGrammars.get(scopeName);
	}
	/**
	* Returns the injections for the given grammar
	*/
	injections(targetScope) {
		return this._injectionGrammars.get(targetScope);
	}
	/**
	* Get the default theme settings
	*/
	getDefaults() {
		return this._theme.getDefaults();
	}
	/**
	* Match a scope in the theme.
	*/
	themeMatch(scopePath) {
		return this._theme.match(scopePath);
	}
	/**
	* Lookup a grammar.
	*/
	grammarForScopeName(scopeName, initialLanguage, embeddedLanguages, tokenTypes, balancedBracketSelectors) {
		if (!this._grammars.has(scopeName)) {
			let rawGrammar = this._rawGrammars.get(scopeName);
			if (!rawGrammar) {
				return null;
			}
			this._grammars.set(scopeName, createGrammar(scopeName, rawGrammar, initialLanguage, embeddedLanguages, tokenTypes, balancedBracketSelectors, this, this._onigLib));
		}
		return this._grammars.get(scopeName);
	}
};
var Registry = class {
	_options;
	_syncRegistry;
	_ensureGrammarCache;
	constructor(options) {
		this._options = options;
		this._syncRegistry = new SyncRegistry(Theme.createFromRawTheme(options.theme, options.colorMap), options.onigLib);
		this._ensureGrammarCache = /* @__PURE__ */ new Map();
	}
	dispose() {
		this._syncRegistry.dispose();
	}
	/**
	* Change the theme. Once called, no previous `ruleStack` should be used anymore.
	*/
	setTheme(theme, colorMap) {
		this._syncRegistry.setTheme(Theme.createFromRawTheme(theme, colorMap));
	}
	/**
	* Returns a lookup array for color ids.
	*/
	getColorMap() {
		return this._syncRegistry.getColorMap();
	}
	/**
	* Load the grammar for `scopeName` and all referenced included grammars asynchronously.
	* Please do not use language id 0.
	*/
	loadGrammarWithEmbeddedLanguages(initialScopeName, initialLanguage, embeddedLanguages) {
		return this.loadGrammarWithConfiguration(initialScopeName, initialLanguage, { embeddedLanguages });
	}
	/**
	* Load the grammar for `scopeName` and all referenced included grammars asynchronously.
	* Please do not use language id 0.
	*/
	loadGrammarWithConfiguration(initialScopeName, initialLanguage, configuration) {
		return this._loadGrammar(initialScopeName, initialLanguage, configuration.embeddedLanguages, configuration.tokenTypes, new BalancedBracketSelectors(configuration.balancedBracketSelectors || [], configuration.unbalancedBracketSelectors || []));
	}
	/**
	* Load the grammar for `scopeName` and all referenced included grammars asynchronously.
	*/
	loadGrammar(initialScopeName) {
		return this._loadGrammar(initialScopeName, 0, null, null, null);
	}
	_loadGrammar(initialScopeName, initialLanguage, embeddedLanguages, tokenTypes, balancedBracketSelectors) {
		const dependencyProcessor = new ScopeDependencyProcessor(this._syncRegistry, initialScopeName);
		while (dependencyProcessor.Q.length > 0) {
			dependencyProcessor.Q.map((request) => this._loadSingleGrammar(request.scopeName));
			dependencyProcessor.processQueue();
		}
		return this._grammarForScopeName(initialScopeName, initialLanguage, embeddedLanguages, tokenTypes, balancedBracketSelectors);
	}
	_loadSingleGrammar(scopeName) {
		if (!this._ensureGrammarCache.has(scopeName)) {
			this._doLoadSingleGrammar(scopeName);
			this._ensureGrammarCache.set(scopeName, true);
		}
	}
	_doLoadSingleGrammar(scopeName) {
		const grammar = this._options.loadGrammar(scopeName);
		if (grammar) {
			const injections = typeof this._options.getInjections === "function" ? this._options.getInjections(scopeName) : void 0;
			this._syncRegistry.addGrammar(grammar, injections);
		}
	}
	/**
	* Adds a rawGrammar.
	*/
	addGrammar(rawGrammar, injections = [], initialLanguage = 0, embeddedLanguages = null) {
		this._syncRegistry.addGrammar(rawGrammar, injections);
		return this._grammarForScopeName(rawGrammar.scopeName, initialLanguage, embeddedLanguages);
	}
	/**
	* Get the grammar for `scopeName`. The grammar must first be created via `loadGrammar` or `addGrammar`.
	*/
	_grammarForScopeName(scopeName, initialLanguage = 0, embeddedLanguages = null, tokenTypes = null, balancedBracketSelectors = null) {
		return this._syncRegistry.grammarForScopeName(scopeName, initialLanguage, embeddedLanguages, tokenTypes, balancedBracketSelectors);
	}
};
var INITIAL = StateStackImpl.NULL;

//#endregion
//#region ../../node_modules/.bun/@shikijs+primitive@4.0.2/node_modules/@shikijs/primitive/dist/index.mjs
function resolveColorReplacements(theme, options) {
	const replacements = typeof theme === "string" ? {} : { ...theme.colorReplacements };
	const themeName = typeof theme === "string" ? theme : theme.name;
	for (const [key$1, value] of Object.entries(options?.colorReplacements || {})) if (typeof value === "string") replacements[key$1] = value;
	else if (key$1 === themeName) Object.assign(replacements, value);
	return replacements;
}
function applyColorReplacements(color, replacements) {
	if (!color) return color;
	return replacements?.[color?.toLowerCase()] || color;
}
function toArray(x$1) {
	return Array.isArray(x$1) ? x$1 : [x$1];
}
/**
* Normalize a getter to a promise.
*/
async function normalizeGetter(p$1) {
	return Promise.resolve(typeof p$1 === "function" ? p$1() : p$1).then((r$3) => r$3.default || r$3);
}
/**
* Check if the language is plaintext that is ignored by Shiki.
*
* Hard-coded plain text languages: `plaintext`, `txt`, `text`, `plain`.
*/
function isPlainLang(lang) {
	return !lang || [
		"plaintext",
		"txt",
		"text",
		"plain"
	].includes(lang);
}
/**
* Check if the language is specially handled or bypassed by Shiki.
*
* Hard-coded languages: `ansi` and plaintexts like `plaintext`, `txt`, `text`, `plain`.
*/
function isSpecialLang(lang) {
	return lang === "ansi" || isPlainLang(lang);
}
/**
* Check if the theme is specially handled or bypassed by Shiki.
*
* Hard-coded themes: `none`.
*/
function isNoneTheme(theme) {
	return theme === "none";
}
/**
* Check if the theme is specially handled or bypassed by Shiki.
*
* Hard-coded themes: `none`.
*/
function isSpecialTheme(theme) {
	return isNoneTheme(theme);
}
/**
* Split a string into lines, each line preserves the line ending.
*
* @param code - The code string to split into lines
* @param preserveEnding - Whether to preserve line endings in the result
* @returns Array of tuples containing [line content, offset index]
*
* @example
* ```ts
* splitLines('hello\nworld', false)
* // => [['hello', 0], ['world', 6]]
*
* splitLines('hello\nworld', true)
* // => [['hello\n', 0], ['world', 6]]
* ```
*/
function splitLines$1(code, preserveEnding = false) {
	if (code.length === 0) return [["", 0]];
	const parts = code.split(/(\r?\n)/g);
	let index = 0;
	const lines = [];
	for (let i$2 = 0; i$2 < parts.length; i$2 += 2) {
		const line = preserveEnding ? parts[i$2] + (parts[i$2 + 1] || "") : parts[i$2];
		lines.push([line, index]);
		index += parts[i$2].length;
		index += parts[i$2 + 1]?.length || 0;
	}
	return lines;
}
/**
* https://github.com/microsoft/vscode/blob/f7f05dee53fb33fe023db2e06e30a89d3094488f/src/vs/platform/theme/common/colorRegistry.ts#L258-L268
*/
const VSCODE_FALLBACK_EDITOR_FG = {
	light: "#333333",
	dark: "#bbbbbb"
};
const VSCODE_FALLBACK_EDITOR_BG = {
	light: "#fffffe",
	dark: "#1e1e1e"
};
const RESOLVED_KEY = "__shiki_resolved";
/**
* Normalize a textmate theme to shiki theme
*/
function normalizeTheme(rawTheme) {
	if (rawTheme?.[RESOLVED_KEY]) return rawTheme;
	const theme = { ...rawTheme };
	if (theme.tokenColors && !theme.settings) {
		theme.settings = theme.tokenColors;
		delete theme.tokenColors;
	}
	theme.type ||= "dark";
	theme.colorReplacements = { ...theme.colorReplacements };
	theme.settings ||= [];
	let { bg, fg } = theme;
	if (!bg || !fg) {
		/**
		* First try:
		* Theme might contain a global `tokenColor` without `name` or `scope`
		* Used as default value for foreground/background
		*/
		const globalSetting = theme.settings ? theme.settings.find((s$1) => !s$1.name && !s$1.scope) : void 0;
		if (globalSetting?.settings?.foreground) fg = globalSetting.settings.foreground;
		if (globalSetting?.settings?.background) bg = globalSetting.settings.background;
		/**
		* Second try:
		* If there's no global `tokenColor` without `name` or `scope`
		* Use `editor.foreground` and `editor.background`
		*/
		if (!fg && theme?.colors?.["editor.foreground"]) fg = theme.colors["editor.foreground"];
		if (!bg && theme?.colors?.["editor.background"]) bg = theme.colors["editor.background"];
		/**
		* Last try:
		* If there's no fg/bg color specified in theme, use default
		*/
		if (!fg) fg = theme.type === "light" ? VSCODE_FALLBACK_EDITOR_FG.light : VSCODE_FALLBACK_EDITOR_FG.dark;
		if (!bg) bg = theme.type === "light" ? VSCODE_FALLBACK_EDITOR_BG.light : VSCODE_FALLBACK_EDITOR_BG.dark;
		theme.fg = fg;
		theme.bg = bg;
	}
	if (!(theme.settings[0] && theme.settings[0].settings && !theme.settings[0].scope)) theme.settings.unshift({ settings: {
		foreground: theme.fg,
		background: theme.bg
	} });
	let replacementCount = 0;
	const replacementMap = /* @__PURE__ */ new Map();
	function getReplacementColor(value) {
		if (replacementMap.has(value)) return replacementMap.get(value);
		replacementCount += 1;
		const hex = `#${replacementCount.toString(16).padStart(8, "0").toLowerCase()}`;
		if (theme.colorReplacements?.[`#${hex}`]) return getReplacementColor(value);
		replacementMap.set(value, hex);
		return hex;
	}
	theme.settings = theme.settings.map((setting) => {
		const replaceFg = setting.settings?.foreground && !setting.settings.foreground.startsWith("#");
		const replaceBg = setting.settings?.background && !setting.settings.background.startsWith("#");
		if (!replaceFg && !replaceBg) return setting;
		const clone$1 = {
			...setting,
			settings: { ...setting.settings }
		};
		if (replaceFg) {
			const replacement = getReplacementColor(setting.settings.foreground);
			theme.colorReplacements[replacement] = setting.settings.foreground;
			clone$1.settings.foreground = replacement;
		}
		if (replaceBg) {
			const replacement = getReplacementColor(setting.settings.background);
			theme.colorReplacements[replacement] = setting.settings.background;
			clone$1.settings.background = replacement;
		}
		return clone$1;
	});
	for (const key$1 of Object.keys(theme.colors || {})) if (key$1 === "editor.foreground" || key$1 === "editor.background" || key$1.startsWith("terminal.ansi")) {
		if (!theme.colors[key$1]?.startsWith("#")) {
			const replacement = getReplacementColor(theme.colors[key$1]);
			theme.colorReplacements[replacement] = theme.colors[key$1];
			theme.colors[key$1] = replacement;
		}
	}
	Object.defineProperty(theme, RESOLVED_KEY, {
		enumerable: false,
		writable: false,
		value: true
	});
	return theme;
}
/**
* Resolve
*/
async function resolveLangs(langs) {
	return Array.from(new Set((await Promise.all(langs.filter((l$2) => !isSpecialLang(l$2)).map(async (lang) => await normalizeGetter(lang).then((r$3) => Array.isArray(r$3) ? r$3 : [r$3])))).flat()));
}
async function resolveThemes(themes) {
	return (await Promise.all(themes.map(async (theme) => isSpecialTheme(theme) ? null : normalizeTheme(await normalizeGetter(theme))))).filter((i$2) => !!i$2);
}
function resolveLangAlias(name, alias) {
	if (!alias) return name;
	if (alias[name]) {
		const resolved = new Set([name]);
		while (alias[name]) {
			name = alias[name];
			if (resolved.has(name)) throw new ShikiError$1(`Circular alias \`${Array.from(resolved).join(" -> ")} -> ${name}\``);
			resolved.add(name);
		}
	}
	return name;
}
var Registry$1 = class extends Registry {
	_resolvedThemes = /* @__PURE__ */ new Map();
	_resolvedGrammars = /* @__PURE__ */ new Map();
	_langMap = /* @__PURE__ */ new Map();
	_langGraph = /* @__PURE__ */ new Map();
	_textmateThemeCache = /* @__PURE__ */ new WeakMap();
	_loadedThemesCache = null;
	_loadedLanguagesCache = null;
	constructor(_resolver, _themes, _langs, _alias = {}) {
		super(_resolver);
		this._resolver = _resolver;
		this._themes = _themes;
		this._langs = _langs;
		this._alias = _alias;
		this._themes.map((t) => this.loadTheme(t));
		this.loadLanguages(this._langs);
	}
	getTheme(theme) {
		if (typeof theme === "string") return this._resolvedThemes.get(theme);
		else return this.loadTheme(theme);
	}
	loadTheme(theme) {
		const _theme = normalizeTheme(theme);
		if (_theme.name) {
			this._resolvedThemes.set(_theme.name, _theme);
			this._loadedThemesCache = null;
		}
		return _theme;
	}
	getLoadedThemes() {
		if (!this._loadedThemesCache) this._loadedThemesCache = [...this._resolvedThemes.keys()];
		return this._loadedThemesCache;
	}
	setTheme(theme) {
		let textmateTheme = this._textmateThemeCache.get(theme);
		if (!textmateTheme) {
			textmateTheme = Theme.createFromRawTheme(theme);
			this._textmateThemeCache.set(theme, textmateTheme);
		}
		this._syncRegistry.setTheme(textmateTheme);
	}
	getGrammar(name) {
		name = resolveLangAlias(name, this._alias);
		return this._resolvedGrammars.get(name);
	}
	loadLanguage(lang) {
		if (this.getGrammar(lang.name)) return;
		const embeddedLazilyBy = new Set([...this._langMap.values()].filter((i$2) => i$2.embeddedLangsLazy?.includes(lang.name)));
		this._resolver.addLanguage(lang);
		const grammarConfig = {
			balancedBracketSelectors: lang.balancedBracketSelectors || ["*"],
			unbalancedBracketSelectors: lang.unbalancedBracketSelectors || []
		};
		this._syncRegistry._rawGrammars.set(lang.scopeName, lang);
		const g = this.loadGrammarWithConfiguration(lang.scopeName, 1, grammarConfig);
		g.name = lang.name;
		this._resolvedGrammars.set(lang.name, g);
		if (lang.aliases) lang.aliases.forEach((alias) => {
			this._alias[alias] = lang.name;
		});
		this._loadedLanguagesCache = null;
		if (embeddedLazilyBy.size) for (const e of embeddedLazilyBy) {
			this._resolvedGrammars.delete(e.name);
			this._loadedLanguagesCache = null;
			this._syncRegistry?._injectionGrammars?.delete(e.scopeName);
			this._syncRegistry?._grammars?.delete(e.scopeName);
			this.loadLanguage(this._langMap.get(e.name));
		}
	}
	dispose() {
		super.dispose();
		this._resolvedThemes.clear();
		this._resolvedGrammars.clear();
		this._langMap.clear();
		this._langGraph.clear();
		this._loadedThemesCache = null;
	}
	loadLanguages(langs) {
		for (const lang of langs) this.resolveEmbeddedLanguages(lang);
		const langsGraphArray = Array.from(this._langGraph.entries());
		const missingLangs = langsGraphArray.filter(([_$2, lang]) => !lang);
		if (missingLangs.length) {
			const dependents = langsGraphArray.filter(([_$2, lang]) => {
				if (!lang) return false;
				return (lang.embeddedLanguages || lang.embeddedLangs)?.some((l$2) => missingLangs.map(([name]) => name).includes(l$2));
			}).filter((lang) => !missingLangs.includes(lang));
			throw new ShikiError$1(`Missing languages ${missingLangs.map(([name]) => `\`${name}\``).join(", ")}, required by ${dependents.map(([name]) => `\`${name}\``).join(", ")}`);
		}
		for (const [_$2, lang] of langsGraphArray) this._resolver.addLanguage(lang);
		for (const [_$2, lang] of langsGraphArray) this.loadLanguage(lang);
	}
	getLoadedLanguages() {
		if (!this._loadedLanguagesCache) this._loadedLanguagesCache = [...new Set([...this._resolvedGrammars.keys(), ...Object.keys(this._alias)])];
		return this._loadedLanguagesCache;
	}
	resolveEmbeddedLanguages(lang) {
		this._langMap.set(lang.name, lang);
		this._langGraph.set(lang.name, lang);
		const embedded = lang.embeddedLanguages ?? lang.embeddedLangs;
		if (embedded) for (const embeddedLang of embedded) this._langGraph.set(embeddedLang, this._langMap.get(embeddedLang));
	}
};
var Resolver = class {
	_langs = /* @__PURE__ */ new Map();
	_scopeToLang = /* @__PURE__ */ new Map();
	_injections = /* @__PURE__ */ new Map();
	_onigLib;
	constructor(engine, langs) {
		this._onigLib = {
			createOnigScanner: (patterns) => engine.createScanner(patterns),
			createOnigString: (s$1) => engine.createString(s$1)
		};
		langs.forEach((i$2) => this.addLanguage(i$2));
	}
	get onigLib() {
		return this._onigLib;
	}
	getLangRegistration(langIdOrAlias) {
		return this._langs.get(langIdOrAlias);
	}
	loadGrammar(scopeName) {
		return this._scopeToLang.get(scopeName);
	}
	addLanguage(l$2) {
		this._langs.set(l$2.name, l$2);
		if (l$2.aliases) l$2.aliases.forEach((a$1) => {
			this._langs.set(a$1, l$2);
		});
		this._scopeToLang.set(l$2.scopeName, l$2);
		if (l$2.injectTo) l$2.injectTo.forEach((i$2) => {
			if (!this._injections.get(i$2)) this._injections.set(i$2, []);
			this._injections.get(i$2).push(l$2.scopeName);
		});
	}
	getInjections(scopeName) {
		const scopeParts = scopeName.split(".");
		let injections = [];
		for (let i$2 = 1; i$2 <= scopeParts.length; i$2++) {
			const subScopeName = scopeParts.slice(0, i$2).join(".");
			injections = [...injections, ...this._injections.get(subScopeName) || []];
		}
		return injections;
	}
};
let instancesCount = 0;
/**
* Get the minimal shiki primitive instance.
*
* Requires to provide the engine and all themes and languages upfront.
*/
function createShikiPrimitive(options) {
	instancesCount += 1;
	if (options.warnings !== false && instancesCount >= 10 && instancesCount % 10 === 0) console.warn(`[Shiki] ${instancesCount} instances have been created. Shiki is supposed to be used as a singleton, consider refactoring your code to cache your highlighter instance; Or call \`highlighter.dispose()\` to release unused instances.`);
	let isDisposed = false;
	if (!options.engine) throw new ShikiError$1("`engine` option is required for synchronous mode");
	const langs = (options.langs || []).flat(1);
	const themes = (options.themes || []).flat(1).map(normalizeTheme);
	const _registry = new Registry$1(new Resolver(options.engine, langs), themes, langs, options.langAlias);
	let _lastTheme;
	function resolveLangAlias$1(name) {
		return resolveLangAlias(name, options.langAlias);
	}
	function getLanguage(name) {
		ensureNotDisposed();
		const _lang = _registry.getGrammar(typeof name === "string" ? name : name.name);
		if (!_lang) throw new ShikiError$1(`Language \`${name}\` not found, you may need to load it first`);
		return _lang;
	}
	function getTheme(name) {
		if (name === "none") return {
			bg: "",
			fg: "",
			name: "none",
			settings: [],
			type: "dark"
		};
		ensureNotDisposed();
		const _theme = _registry.getTheme(name);
		if (!_theme) throw new ShikiError$1(`Theme \`${name}\` not found, you may need to load it first`);
		return _theme;
	}
	function setTheme(name) {
		ensureNotDisposed();
		const theme = getTheme(name);
		if (_lastTheme !== name) {
			_registry.setTheme(theme);
			_lastTheme = name;
		}
		return {
			theme,
			colorMap: _registry.getColorMap()
		};
	}
	function getLoadedThemes() {
		ensureNotDisposed();
		return _registry.getLoadedThemes();
	}
	function getLoadedLanguages() {
		ensureNotDisposed();
		return _registry.getLoadedLanguages();
	}
	function loadLanguageSync(...langs$1) {
		ensureNotDisposed();
		_registry.loadLanguages(langs$1.flat(1));
	}
	async function loadLanguage(...langs$1) {
		return loadLanguageSync(await resolveLangs(langs$1));
	}
	function loadThemeSync(...themes$1) {
		ensureNotDisposed();
		for (const theme of themes$1.flat(1)) _registry.loadTheme(theme);
	}
	async function loadTheme(...themes$1) {
		ensureNotDisposed();
		return loadThemeSync(await resolveThemes(themes$1));
	}
	function ensureNotDisposed() {
		if (isDisposed) throw new ShikiError$1("Shiki instance has been disposed");
	}
	function dispose() {
		if (isDisposed) return;
		isDisposed = true;
		_registry.dispose();
		instancesCount -= 1;
	}
	return {
		setTheme,
		getTheme,
		getLanguage,
		getLoadedThemes,
		getLoadedLanguages,
		resolveLangAlias: resolveLangAlias$1,
		loadLanguage,
		loadLanguageSync,
		loadTheme,
		loadThemeSync,
		dispose,
		[Symbol.dispose]: dispose
	};
}
/**
* @deprecated Use `createShikiPrimitive` instead.
*/
const createShikiInternalSync = createShikiPrimitive;
/**
* Get the minimal shiki primitive instance.
*/
async function createShikiPrimitiveAsync(options) {
	if (!options.engine) console.warn("`engine` option is required. Use `createOnigurumaEngine` or `createJavaScriptRegexEngine` to create an engine.");
	const [themes, langs, engine] = await Promise.all([
		resolveThemes(options.themes || []),
		resolveLangs(options.langs || []),
		options.engine
	]);
	return createShikiPrimitive({
		...options,
		themes,
		langs,
		engine
	});
}
/**
* @deprecated Use `createShikiPrimitiveAsync` instead.
*/
const createShikiInternal = createShikiPrimitiveAsync;
const _grammarStateMap = /* @__PURE__ */ new WeakMap();
function setLastGrammarStateToMap(keys, state) {
	_grammarStateMap.set(keys, state);
}
function getLastGrammarStateFromMap(keys) {
	return _grammarStateMap.get(keys);
}
/**
* GrammarState is a special reference object that holds the state of a grammar.
*
* It's used to highlight code snippets that are part of the target language.
*/
var GrammarState = class GrammarState$1 {
	/**
	* Theme to Stack mapping
	*/
	_stacks = {};
	lang;
	get themes() {
		return Object.keys(this._stacks);
	}
	get theme() {
		return this.themes[0];
	}
	get _stack() {
		return this._stacks[this.theme];
	}
	/**
	* Static method to create a initial grammar state.
	*/
	static initial(lang, themes) {
		return new GrammarState$1(Object.fromEntries(toArray(themes).map((theme) => [theme, INITIAL])), lang);
	}
	constructor(...args) {
		if (args.length === 2) {
			const [stacksMap, lang] = args;
			this.lang = lang;
			this._stacks = stacksMap;
		} else {
			const [stack, lang, theme] = args;
			this.lang = lang;
			this._stacks = { [theme]: stack };
		}
	}
	/**
	* Get the internal stack object.
	* @internal
	*/
	getInternalStack(theme = this.theme) {
		return this._stacks[theme];
	}
	getScopes(theme = this.theme) {
		return getScopes(this._stacks[theme]);
	}
	toJSON() {
		return {
			lang: this.lang,
			theme: this.theme,
			themes: this.themes,
			scopes: this.getScopes()
		};
	}
};
function getScopes(stack) {
	const scopes = [];
	const visited = /* @__PURE__ */ new Set();
	function pushScope(stack$1) {
		if (visited.has(stack$1)) return;
		visited.add(stack$1);
		const name = stack$1?.nameScopesList?.scopeName;
		if (name) scopes.push(name);
		if (stack$1.parent) pushScope(stack$1.parent);
	}
	pushScope(stack);
	return scopes;
}
function getGrammarStack(state, theme) {
	if (!(state instanceof GrammarState)) throw new ShikiError$1("Invalid grammar state");
	return state.getInternalStack(theme);
}
/**
* Code to tokens, with a simple theme.
*/
function codeToTokensBase(primitive, code, options = {}) {
	const { theme: themeName = primitive.getLoadedThemes()[0] } = options;
	if (isPlainLang(primitive.resolveLangAlias(options.lang || "text")) || isNoneTheme(themeName)) return splitLines$1(code).map((line) => [{
		content: line[0],
		offset: line[1]
	}]);
	const { theme, colorMap } = primitive.setTheme(themeName);
	const _grammar = primitive.getLanguage(options.lang || "text");
	if (options.grammarState) {
		if (options.grammarState.lang !== _grammar.name) throw new ShikiError$1(`Grammar state language "${options.grammarState.lang}" does not match highlight language "${_grammar.name}"`);
		if (!options.grammarState.themes.includes(theme.name)) throw new ShikiError$1(`Grammar state themes "${options.grammarState.themes}" do not contain highlight theme "${theme.name}"`);
	}
	return tokenizeWithTheme(code, _grammar, theme, colorMap, options);
}
function getLastGrammarState(...args) {
	if (args.length === 2) return getLastGrammarStateFromMap(args[1]);
	const [primitive, code, options = {}] = args;
	const { lang = "text", theme: themeName = primitive.getLoadedThemes()[0] } = options;
	if (isPlainLang(lang) || isNoneTheme(themeName)) throw new ShikiError$1("Plain language does not have grammar state");
	if (lang === "ansi") throw new ShikiError$1("ANSI language does not have grammar state");
	const { theme, colorMap } = primitive.setTheme(themeName);
	const _grammar = primitive.getLanguage(lang);
	return new GrammarState(_tokenizeWithTheme(code, _grammar, theme, colorMap, options).stateStack, _grammar.name, theme.name);
}
function tokenizeWithTheme(code, grammar, theme, colorMap, options) {
	const result = _tokenizeWithTheme(code, grammar, theme, colorMap, options);
	const grammarState = new GrammarState(result.stateStack, grammar.name, theme.name);
	setLastGrammarStateToMap(result.tokens, grammarState);
	return result.tokens;
}
function _tokenizeWithTheme(code, grammar, theme, colorMap, options) {
	const colorReplacements = resolveColorReplacements(theme, options);
	const { tokenizeMaxLineLength = 0, tokenizeTimeLimit = 500 } = options;
	const lines = splitLines$1(code);
	let stateStack = options.grammarState ? getGrammarStack(options.grammarState, theme.name) ?? INITIAL : options.grammarContextCode != null ? _tokenizeWithTheme(options.grammarContextCode, grammar, theme, colorMap, {
		...options,
		grammarState: void 0,
		grammarContextCode: void 0
	}).stateStack : INITIAL;
	let actual = [];
	const final = [];
	for (let i$2 = 0, len = lines.length; i$2 < len; i$2++) {
		const [line, lineOffset] = lines[i$2];
		if (line === "") {
			actual = [];
			final.push([]);
			continue;
		}
		if (tokenizeMaxLineLength > 0 && line.length >= tokenizeMaxLineLength) {
			actual = [];
			final.push([{
				content: line,
				offset: lineOffset,
				color: "",
				fontStyle: 0
			}]);
			continue;
		}
		let resultWithScopes;
		let tokensWithScopes;
		let tokensWithScopesIndex;
		if (options.includeExplanation) {
			resultWithScopes = grammar.tokenizeLine(line, stateStack, tokenizeTimeLimit);
			tokensWithScopes = resultWithScopes.tokens;
			tokensWithScopesIndex = 0;
		}
		const result = grammar.tokenizeLine2(line, stateStack, tokenizeTimeLimit);
		const tokensLength = result.tokens.length / 2;
		for (let j$1 = 0; j$1 < tokensLength; j$1++) {
			const startIndex = result.tokens[2 * j$1];
			const nextStartIndex = j$1 + 1 < tokensLength ? result.tokens[2 * j$1 + 2] : line.length;
			if (startIndex === nextStartIndex) continue;
			const metadata = result.tokens[2 * j$1 + 1];
			const color = applyColorReplacements(colorMap[EncodedTokenMetadata.getForeground(metadata)], colorReplacements);
			const fontStyle = EncodedTokenMetadata.getFontStyle(metadata);
			const token$1 = {
				content: line.substring(startIndex, nextStartIndex),
				offset: lineOffset + startIndex,
				color,
				fontStyle
			};
			if (options.includeExplanation) {
				const themeSettingsSelectors = [];
				if (options.includeExplanation !== "scopeName") for (const setting of theme.settings) {
					let selectors;
					switch (typeof setting.scope) {
						case "string":
							selectors = setting.scope.split(/,/).map((scope) => scope.trim());
							break;
						case "object":
							selectors = setting.scope;
							break;
						default: continue;
					}
					themeSettingsSelectors.push({
						settings: setting,
						selectors: selectors.map((selector) => selector.split(/ /))
					});
				}
				token$1.explanation = [];
				let offset = 0;
				while (startIndex + offset < nextStartIndex) {
					const tokenWithScopes = tokensWithScopes[tokensWithScopesIndex];
					const tokenWithScopesText = line.substring(tokenWithScopes.startIndex, tokenWithScopes.endIndex);
					offset += tokenWithScopesText.length;
					token$1.explanation.push({
						content: tokenWithScopesText,
						scopes: options.includeExplanation === "scopeName" ? explainThemeScopesNameOnly(tokenWithScopes.scopes) : explainThemeScopesFull(themeSettingsSelectors, tokenWithScopes.scopes)
					});
					tokensWithScopesIndex += 1;
				}
			}
			actual.push(token$1);
		}
		final.push(actual);
		actual = [];
		stateStack = result.ruleStack;
	}
	return {
		tokens: final,
		stateStack
	};
}
function explainThemeScopesNameOnly(scopes) {
	return scopes.map((scope) => ({ scopeName: scope }));
}
function explainThemeScopesFull(themeSelectors, scopes) {
	const result = [];
	for (let i$2 = 0, len = scopes.length; i$2 < len; i$2++) {
		const scope = scopes[i$2];
		result[i$2] = {
			scopeName: scope,
			themeMatches: explainThemeScope(themeSelectors, scope, scopes.slice(0, i$2))
		};
	}
	return result;
}
function matchesOne(selector, scope) {
	return selector === scope || scope.substring(0, selector.length) === selector && scope[selector.length] === ".";
}
function matches(selectors, scope, parentScopes) {
	if (!matchesOne(selectors[selectors.length - 1], scope)) return false;
	let selectorParentIndex = selectors.length - 2;
	let parentIndex = parentScopes.length - 1;
	while (selectorParentIndex >= 0 && parentIndex >= 0) {
		if (matchesOne(selectors[selectorParentIndex], parentScopes[parentIndex])) selectorParentIndex -= 1;
		parentIndex -= 1;
	}
	if (selectorParentIndex === -1) return true;
	return false;
}
function explainThemeScope(themeSettingsSelectors, scope, parentScopes) {
	const result = [];
	for (const { selectors, settings } of themeSettingsSelectors) for (const selectorPieces of selectors) if (matches(selectorPieces, scope, parentScopes)) {
		result.push(settings);
		break;
	}
	return result;
}
/**
* Get tokens with multiple themes
*/
function codeToTokensWithThemes(primitive, code, options, codeToTokensBaseFn = codeToTokensBase) {
	const themes = Object.entries(options.themes).filter((i$2) => i$2[1]).map((i$2) => ({
		color: i$2[0],
		theme: i$2[1]
	}));
	const themedTokens = themes.map((t) => {
		const tokens$1 = codeToTokensBaseFn(primitive, code, {
			...options,
			theme: t.theme
		});
		return {
			tokens: tokens$1,
			state: getLastGrammarStateFromMap(tokens$1),
			theme: typeof t.theme === "string" ? t.theme : t.theme.name
		};
	});
	const tokens = alignThemesTokenization(...themedTokens.map((i$2) => i$2.tokens));
	const mergedTokens = tokens[0].map((line, lineIdx) => line.map((_token, tokenIdx) => {
		const mergedToken = {
			content: _token.content,
			variants: {},
			offset: _token.offset
		};
		if ("includeExplanation" in options && options.includeExplanation) mergedToken.explanation = _token.explanation;
		tokens.forEach((t, themeIdx) => {
			const { content: _$2, explanation: __, offset: ___,...styles } = t[lineIdx][tokenIdx];
			mergedToken.variants[themes[themeIdx].color] = styles;
		});
		return mergedToken;
	}));
	const mergedGrammarState = themedTokens[0].state ? new GrammarState(Object.fromEntries(themedTokens.map((s$1) => [s$1.theme, s$1.state?.getInternalStack(s$1.theme)])), themedTokens[0].state.lang) : void 0;
	if (mergedGrammarState) setLastGrammarStateToMap(mergedTokens, mergedGrammarState);
	return mergedTokens;
}
/**
* Break tokens from multiple themes into same tokenization.
*
* For example, given two themes that tokenize `console.log("hello")` as:
*
* - `console . log (" hello ")` (6 tokens)
* - `console .log ( "hello" )` (5 tokens)
*
* This function will return:
*
* - `console . log ( " hello " )` (8 tokens)
* - `console . log ( " hello " )` (8 tokens)
*/
function alignThemesTokenization(...themes) {
	const outThemes = themes.map(() => []);
	const count = themes.length;
	for (let i$2 = 0; i$2 < themes[0].length; i$2++) {
		const lines = themes.map((t) => t[i$2]);
		const outLines = outThemes.map(() => []);
		outThemes.forEach((t, i$3) => t.push(outLines[i$3]));
		const indexes = lines.map(() => 0);
		const current = lines.map((l$2) => l$2[0]);
		while (current.every((t) => t)) {
			const minLength = Math.min(...current.map((t) => t.content.length));
			for (let n = 0; n < count; n++) {
				const token$1 = current[n];
				if (token$1.content.length === minLength) {
					outLines[n].push(token$1);
					indexes[n] += 1;
					current[n] = lines[n][indexes[n]];
				} else {
					outLines[n].push({
						...token$1,
						content: token$1.content.slice(0, minLength)
					});
					current[n] = {
						...token$1,
						content: token$1.content.slice(minLength),
						offset: token$1.offset + minLength
					};
				}
			}
		}
	}
	return outThemes;
}

//#endregion
//#region ../../node_modules/.bun/html-void-elements@3.0.0/node_modules/html-void-elements/index.js
/**
* List of HTML void tag names.
*
* @type {Array<string>}
*/
const htmlVoidElements = [
	"area",
	"base",
	"basefont",
	"bgsound",
	"br",
	"col",
	"command",
	"embed",
	"frame",
	"hr",
	"image",
	"img",
	"input",
	"keygen",
	"link",
	"meta",
	"param",
	"source",
	"track",
	"wbr"
];

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/util/schema.js
/**
* @import {Schema as SchemaType, Space} from 'property-information'
*/
/** @type {SchemaType} */
var Schema = class {
	/**
	* @param {SchemaType['property']} property
	*   Property.
	* @param {SchemaType['normal']} normal
	*   Normal.
	* @param {Space | undefined} [space]
	*   Space.
	* @returns
	*   Schema.
	*/
	constructor(property, normal, space) {
		this.normal = normal;
		this.property = property;
		if (space) {
			this.space = space;
		}
	}
};
Schema.prototype.normal = {};
Schema.prototype.property = {};
Schema.prototype.space = undefined;

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/util/merge.js
/**
* @param {ReadonlyArray<Schema>} definitions
*   Definitions.
* @param {Space | undefined} [space]
*   Space.
* @returns {Schema}
*   Schema.
*/
function merge(definitions, space) {
	/** @type {Record<string, Info>} */
	const property = {};
	/** @type {Record<string, string>} */
	const normal = {};
	for (const definition of definitions) {
		Object.assign(property, definition.property);
		Object.assign(normal, definition.normal);
	}
	return new Schema(property, normal, space);
}

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/normalize.js
/**
* Get the cleaned case insensitive form of an attribute or property.
*
* @param {string} value
*   An attribute-like or property-like name.
* @returns {string}
*   Value that can be used to look up the properly cased property on a
*   `Schema`.
*/
function normalize(value) {
	return value.toLowerCase();
}

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/util/info.js
/**
* @import {Info as InfoType} from 'property-information'
*/
/** @type {InfoType} */
var Info = class {
	/**
	* @param {string} property
	*   Property.
	* @param {string} attribute
	*   Attribute.
	* @returns
	*   Info.
	*/
	constructor(property, attribute) {
		this.attribute = attribute;
		this.property = property;
	}
};
Info.prototype.attribute = "";
Info.prototype.booleanish = false;
Info.prototype.boolean = false;
Info.prototype.commaOrSpaceSeparated = false;
Info.prototype.commaSeparated = false;
Info.prototype.defined = false;
Info.prototype.mustUseProperty = false;
Info.prototype.number = false;
Info.prototype.overloadedBoolean = false;
Info.prototype.property = "";
Info.prototype.spaceSeparated = false;
Info.prototype.space = undefined;

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/util/types.js
var types_exports = /* @__PURE__ */ __export({
	boolean: () => boolean,
	booleanish: () => booleanish,
	commaOrSpaceSeparated: () => commaOrSpaceSeparated,
	commaSeparated: () => commaSeparated,
	number: () => number,
	overloadedBoolean: () => overloadedBoolean,
	spaceSeparated: () => spaceSeparated
});
let powers = 0;
const boolean = increment();
const booleanish = increment();
const overloadedBoolean = increment();
const number = increment();
const spaceSeparated = increment();
const commaSeparated = increment();
const commaOrSpaceSeparated = increment();
function increment() {
	return 2 ** ++powers;
}

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/util/defined-info.js
const checks = Object.keys(types_exports);
var DefinedInfo = class extends Info {
	/**
	* @constructor
	* @param {string} property
	*   Property.
	* @param {string} attribute
	*   Attribute.
	* @param {number | null | undefined} [mask]
	*   Mask.
	* @param {Space | undefined} [space]
	*   Space.
	* @returns
	*   Info.
	*/
	constructor(property, attribute, mask, space) {
		let index = -1;
		super(property, attribute);
		mark(this, "space", space);
		if (typeof mask === "number") {
			while (++index < checks.length) {
				const check = checks[index];
				mark(this, checks[index], (mask & types_exports[check]) === types_exports[check]);
			}
		}
	}
};
DefinedInfo.prototype.defined = true;
/**
* @template {keyof DefinedInfo} Key
*   Key type.
* @param {DefinedInfo} values
*   Info.
* @param {Key} key
*   Key.
* @param {DefinedInfo[Key]} value
*   Value.
* @returns {undefined}
*   Nothing.
*/
function mark(values, key$1, value) {
	if (value) {
		values[key$1] = value;
	}
}

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/util/create.js
/**
* @param {Definition} definition
*   Definition.
* @returns {Schema}
*   Schema.
*/
function create(definition) {
	/** @type {Record<string, Info>} */
	const properties = {};
	/** @type {Record<string, string>} */
	const normals = {};
	for (const [property, value] of Object.entries(definition.properties)) {
		const info = new DefinedInfo(property, definition.transform(definition.attributes || {}, property), value, definition.space);
		if (definition.mustUseProperty && definition.mustUseProperty.includes(property)) {
			info.mustUseProperty = true;
		}
		properties[property] = info;
		normals[normalize(property)] = property;
		normals[normalize(info.attribute)] = property;
	}
	return new Schema(properties, normals, definition.space);
}

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/aria.js
const aria = create({
	properties: {
		ariaActiveDescendant: null,
		ariaAtomic: booleanish,
		ariaAutoComplete: null,
		ariaBusy: booleanish,
		ariaChecked: booleanish,
		ariaColCount: number,
		ariaColIndex: number,
		ariaColSpan: number,
		ariaControls: spaceSeparated,
		ariaCurrent: null,
		ariaDescribedBy: spaceSeparated,
		ariaDetails: null,
		ariaDisabled: booleanish,
		ariaDropEffect: spaceSeparated,
		ariaErrorMessage: null,
		ariaExpanded: booleanish,
		ariaFlowTo: spaceSeparated,
		ariaGrabbed: booleanish,
		ariaHasPopup: null,
		ariaHidden: booleanish,
		ariaInvalid: null,
		ariaKeyShortcuts: null,
		ariaLabel: null,
		ariaLabelledBy: spaceSeparated,
		ariaLevel: number,
		ariaLive: null,
		ariaModal: booleanish,
		ariaMultiLine: booleanish,
		ariaMultiSelectable: booleanish,
		ariaOrientation: null,
		ariaOwns: spaceSeparated,
		ariaPlaceholder: null,
		ariaPosInSet: number,
		ariaPressed: booleanish,
		ariaReadOnly: booleanish,
		ariaRelevant: null,
		ariaRequired: booleanish,
		ariaRoleDescription: spaceSeparated,
		ariaRowCount: number,
		ariaRowIndex: number,
		ariaRowSpan: number,
		ariaSelected: booleanish,
		ariaSetSize: number,
		ariaSort: null,
		ariaValueMax: number,
		ariaValueMin: number,
		ariaValueNow: number,
		ariaValueText: null,
		role: null
	},
	transform(_$2, property) {
		return property === "role" ? property : "aria-" + property.slice(4).toLowerCase();
	}
});

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/util/case-sensitive-transform.js
/**
* @param {Record<string, string>} attributes
*   Attributes.
* @param {string} attribute
*   Attribute.
* @returns {string}
*   Transformed attribute.
*/
function caseSensitiveTransform(attributes, attribute) {
	return attribute in attributes ? attributes[attribute] : attribute;
}

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/util/case-insensitive-transform.js
/**
* @param {Record<string, string>} attributes
*   Attributes.
* @param {string} property
*   Property.
* @returns {string}
*   Transformed property.
*/
function caseInsensitiveTransform(attributes, property) {
	return caseSensitiveTransform(attributes, property.toLowerCase());
}

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/html.js
const html$3 = create({
	attributes: {
		acceptcharset: "accept-charset",
		classname: "class",
		htmlfor: "for",
		httpequiv: "http-equiv"
	},
	mustUseProperty: [
		"checked",
		"multiple",
		"muted",
		"selected"
	],
	properties: {
		abbr: null,
		accept: commaSeparated,
		acceptCharset: spaceSeparated,
		accessKey: spaceSeparated,
		action: null,
		allow: null,
		allowFullScreen: boolean,
		allowPaymentRequest: boolean,
		allowUserMedia: boolean,
		alt: null,
		as: null,
		async: boolean,
		autoCapitalize: null,
		autoComplete: spaceSeparated,
		autoFocus: boolean,
		autoPlay: boolean,
		blocking: spaceSeparated,
		capture: null,
		charSet: null,
		checked: boolean,
		cite: null,
		className: spaceSeparated,
		cols: number,
		colSpan: null,
		content: null,
		contentEditable: booleanish,
		controls: boolean,
		controlsList: spaceSeparated,
		coords: number | commaSeparated,
		crossOrigin: null,
		data: null,
		dateTime: null,
		decoding: null,
		default: boolean,
		defer: boolean,
		dir: null,
		dirName: null,
		disabled: boolean,
		download: overloadedBoolean,
		draggable: booleanish,
		encType: null,
		enterKeyHint: null,
		fetchPriority: null,
		form: null,
		formAction: null,
		formEncType: null,
		formMethod: null,
		formNoValidate: boolean,
		formTarget: null,
		headers: spaceSeparated,
		height: number,
		hidden: overloadedBoolean,
		high: number,
		href: null,
		hrefLang: null,
		htmlFor: spaceSeparated,
		httpEquiv: spaceSeparated,
		id: null,
		imageSizes: null,
		imageSrcSet: null,
		inert: boolean,
		inputMode: null,
		integrity: null,
		is: null,
		isMap: boolean,
		itemId: null,
		itemProp: spaceSeparated,
		itemRef: spaceSeparated,
		itemScope: boolean,
		itemType: spaceSeparated,
		kind: null,
		label: null,
		lang: null,
		language: null,
		list: null,
		loading: null,
		loop: boolean,
		low: number,
		manifest: null,
		max: null,
		maxLength: number,
		media: null,
		method: null,
		min: null,
		minLength: number,
		multiple: boolean,
		muted: boolean,
		name: null,
		nonce: null,
		noModule: boolean,
		noValidate: boolean,
		onAbort: null,
		onAfterPrint: null,
		onAuxClick: null,
		onBeforeMatch: null,
		onBeforePrint: null,
		onBeforeToggle: null,
		onBeforeUnload: null,
		onBlur: null,
		onCancel: null,
		onCanPlay: null,
		onCanPlayThrough: null,
		onChange: null,
		onClick: null,
		onClose: null,
		onContextLost: null,
		onContextMenu: null,
		onContextRestored: null,
		onCopy: null,
		onCueChange: null,
		onCut: null,
		onDblClick: null,
		onDrag: null,
		onDragEnd: null,
		onDragEnter: null,
		onDragExit: null,
		onDragLeave: null,
		onDragOver: null,
		onDragStart: null,
		onDrop: null,
		onDurationChange: null,
		onEmptied: null,
		onEnded: null,
		onError: null,
		onFocus: null,
		onFormData: null,
		onHashChange: null,
		onInput: null,
		onInvalid: null,
		onKeyDown: null,
		onKeyPress: null,
		onKeyUp: null,
		onLanguageChange: null,
		onLoad: null,
		onLoadedData: null,
		onLoadedMetadata: null,
		onLoadEnd: null,
		onLoadStart: null,
		onMessage: null,
		onMessageError: null,
		onMouseDown: null,
		onMouseEnter: null,
		onMouseLeave: null,
		onMouseMove: null,
		onMouseOut: null,
		onMouseOver: null,
		onMouseUp: null,
		onOffline: null,
		onOnline: null,
		onPageHide: null,
		onPageShow: null,
		onPaste: null,
		onPause: null,
		onPlay: null,
		onPlaying: null,
		onPopState: null,
		onProgress: null,
		onRateChange: null,
		onRejectionHandled: null,
		onReset: null,
		onResize: null,
		onScroll: null,
		onScrollEnd: null,
		onSecurityPolicyViolation: null,
		onSeeked: null,
		onSeeking: null,
		onSelect: null,
		onSlotChange: null,
		onStalled: null,
		onStorage: null,
		onSubmit: null,
		onSuspend: null,
		onTimeUpdate: null,
		onToggle: null,
		onUnhandledRejection: null,
		onUnload: null,
		onVolumeChange: null,
		onWaiting: null,
		onWheel: null,
		open: boolean,
		optimum: number,
		pattern: null,
		ping: spaceSeparated,
		placeholder: null,
		playsInline: boolean,
		popover: null,
		popoverTarget: null,
		popoverTargetAction: null,
		poster: null,
		preload: null,
		readOnly: boolean,
		referrerPolicy: null,
		rel: spaceSeparated,
		required: boolean,
		reversed: boolean,
		rows: number,
		rowSpan: number,
		sandbox: spaceSeparated,
		scope: null,
		scoped: boolean,
		seamless: boolean,
		selected: boolean,
		shadowRootClonable: boolean,
		shadowRootDelegatesFocus: boolean,
		shadowRootMode: null,
		shape: null,
		size: number,
		sizes: null,
		slot: null,
		span: number,
		spellCheck: booleanish,
		src: null,
		srcDoc: null,
		srcLang: null,
		srcSet: null,
		start: number,
		step: null,
		style: null,
		tabIndex: number,
		target: null,
		title: null,
		translate: null,
		type: null,
		typeMustMatch: boolean,
		useMap: null,
		value: booleanish,
		width: number,
		wrap: null,
		writingSuggestions: null,
		align: null,
		aLink: null,
		archive: spaceSeparated,
		axis: null,
		background: null,
		bgColor: null,
		border: number,
		borderColor: null,
		bottomMargin: number,
		cellPadding: null,
		cellSpacing: null,
		char: null,
		charOff: null,
		classId: null,
		clear: null,
		code: null,
		codeBase: null,
		codeType: null,
		color: null,
		compact: boolean,
		declare: boolean,
		event: null,
		face: null,
		frame: null,
		frameBorder: null,
		hSpace: number,
		leftMargin: number,
		link: null,
		longDesc: null,
		lowSrc: null,
		marginHeight: number,
		marginWidth: number,
		noResize: boolean,
		noHref: boolean,
		noShade: boolean,
		noWrap: boolean,
		object: null,
		profile: null,
		prompt: null,
		rev: null,
		rightMargin: number,
		rules: null,
		scheme: null,
		scrolling: booleanish,
		standby: null,
		summary: null,
		text: null,
		topMargin: number,
		valueType: null,
		version: null,
		vAlign: null,
		vLink: null,
		vSpace: number,
		allowTransparency: null,
		autoCorrect: null,
		autoSave: null,
		disablePictureInPicture: boolean,
		disableRemotePlayback: boolean,
		prefix: null,
		property: null,
		results: number,
		security: null,
		unselectable: null
	},
	space: "html",
	transform: caseInsensitiveTransform
});

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/svg.js
const svg$1 = create({
	attributes: {
		accentHeight: "accent-height",
		alignmentBaseline: "alignment-baseline",
		arabicForm: "arabic-form",
		baselineShift: "baseline-shift",
		capHeight: "cap-height",
		className: "class",
		clipPath: "clip-path",
		clipRule: "clip-rule",
		colorInterpolation: "color-interpolation",
		colorInterpolationFilters: "color-interpolation-filters",
		colorProfile: "color-profile",
		colorRendering: "color-rendering",
		crossOrigin: "crossorigin",
		dataType: "datatype",
		dominantBaseline: "dominant-baseline",
		enableBackground: "enable-background",
		fillOpacity: "fill-opacity",
		fillRule: "fill-rule",
		floodColor: "flood-color",
		floodOpacity: "flood-opacity",
		fontFamily: "font-family",
		fontSize: "font-size",
		fontSizeAdjust: "font-size-adjust",
		fontStretch: "font-stretch",
		fontStyle: "font-style",
		fontVariant: "font-variant",
		fontWeight: "font-weight",
		glyphName: "glyph-name",
		glyphOrientationHorizontal: "glyph-orientation-horizontal",
		glyphOrientationVertical: "glyph-orientation-vertical",
		hrefLang: "hreflang",
		horizAdvX: "horiz-adv-x",
		horizOriginX: "horiz-origin-x",
		horizOriginY: "horiz-origin-y",
		imageRendering: "image-rendering",
		letterSpacing: "letter-spacing",
		lightingColor: "lighting-color",
		markerEnd: "marker-end",
		markerMid: "marker-mid",
		markerStart: "marker-start",
		navDown: "nav-down",
		navDownLeft: "nav-down-left",
		navDownRight: "nav-down-right",
		navLeft: "nav-left",
		navNext: "nav-next",
		navPrev: "nav-prev",
		navRight: "nav-right",
		navUp: "nav-up",
		navUpLeft: "nav-up-left",
		navUpRight: "nav-up-right",
		onAbort: "onabort",
		onActivate: "onactivate",
		onAfterPrint: "onafterprint",
		onBeforePrint: "onbeforeprint",
		onBegin: "onbegin",
		onCancel: "oncancel",
		onCanPlay: "oncanplay",
		onCanPlayThrough: "oncanplaythrough",
		onChange: "onchange",
		onClick: "onclick",
		onClose: "onclose",
		onCopy: "oncopy",
		onCueChange: "oncuechange",
		onCut: "oncut",
		onDblClick: "ondblclick",
		onDrag: "ondrag",
		onDragEnd: "ondragend",
		onDragEnter: "ondragenter",
		onDragExit: "ondragexit",
		onDragLeave: "ondragleave",
		onDragOver: "ondragover",
		onDragStart: "ondragstart",
		onDrop: "ondrop",
		onDurationChange: "ondurationchange",
		onEmptied: "onemptied",
		onEnd: "onend",
		onEnded: "onended",
		onError: "onerror",
		onFocus: "onfocus",
		onFocusIn: "onfocusin",
		onFocusOut: "onfocusout",
		onHashChange: "onhashchange",
		onInput: "oninput",
		onInvalid: "oninvalid",
		onKeyDown: "onkeydown",
		onKeyPress: "onkeypress",
		onKeyUp: "onkeyup",
		onLoad: "onload",
		onLoadedData: "onloadeddata",
		onLoadedMetadata: "onloadedmetadata",
		onLoadStart: "onloadstart",
		onMessage: "onmessage",
		onMouseDown: "onmousedown",
		onMouseEnter: "onmouseenter",
		onMouseLeave: "onmouseleave",
		onMouseMove: "onmousemove",
		onMouseOut: "onmouseout",
		onMouseOver: "onmouseover",
		onMouseUp: "onmouseup",
		onMouseWheel: "onmousewheel",
		onOffline: "onoffline",
		onOnline: "ononline",
		onPageHide: "onpagehide",
		onPageShow: "onpageshow",
		onPaste: "onpaste",
		onPause: "onpause",
		onPlay: "onplay",
		onPlaying: "onplaying",
		onPopState: "onpopstate",
		onProgress: "onprogress",
		onRateChange: "onratechange",
		onRepeat: "onrepeat",
		onReset: "onreset",
		onResize: "onresize",
		onScroll: "onscroll",
		onSeeked: "onseeked",
		onSeeking: "onseeking",
		onSelect: "onselect",
		onShow: "onshow",
		onStalled: "onstalled",
		onStorage: "onstorage",
		onSubmit: "onsubmit",
		onSuspend: "onsuspend",
		onTimeUpdate: "ontimeupdate",
		onToggle: "ontoggle",
		onUnload: "onunload",
		onVolumeChange: "onvolumechange",
		onWaiting: "onwaiting",
		onZoom: "onzoom",
		overlinePosition: "overline-position",
		overlineThickness: "overline-thickness",
		paintOrder: "paint-order",
		panose1: "panose-1",
		pointerEvents: "pointer-events",
		referrerPolicy: "referrerpolicy",
		renderingIntent: "rendering-intent",
		shapeRendering: "shape-rendering",
		stopColor: "stop-color",
		stopOpacity: "stop-opacity",
		strikethroughPosition: "strikethrough-position",
		strikethroughThickness: "strikethrough-thickness",
		strokeDashArray: "stroke-dasharray",
		strokeDashOffset: "stroke-dashoffset",
		strokeLineCap: "stroke-linecap",
		strokeLineJoin: "stroke-linejoin",
		strokeMiterLimit: "stroke-miterlimit",
		strokeOpacity: "stroke-opacity",
		strokeWidth: "stroke-width",
		tabIndex: "tabindex",
		textAnchor: "text-anchor",
		textDecoration: "text-decoration",
		textRendering: "text-rendering",
		transformOrigin: "transform-origin",
		typeOf: "typeof",
		underlinePosition: "underline-position",
		underlineThickness: "underline-thickness",
		unicodeBidi: "unicode-bidi",
		unicodeRange: "unicode-range",
		unitsPerEm: "units-per-em",
		vAlphabetic: "v-alphabetic",
		vHanging: "v-hanging",
		vIdeographic: "v-ideographic",
		vMathematical: "v-mathematical",
		vectorEffect: "vector-effect",
		vertAdvY: "vert-adv-y",
		vertOriginX: "vert-origin-x",
		vertOriginY: "vert-origin-y",
		wordSpacing: "word-spacing",
		writingMode: "writing-mode",
		xHeight: "x-height",
		playbackOrder: "playbackorder",
		timelineBegin: "timelinebegin"
	},
	properties: {
		about: commaOrSpaceSeparated,
		accentHeight: number,
		accumulate: null,
		additive: null,
		alignmentBaseline: null,
		alphabetic: number,
		amplitude: number,
		arabicForm: null,
		ascent: number,
		attributeName: null,
		attributeType: null,
		azimuth: number,
		bandwidth: null,
		baselineShift: null,
		baseFrequency: null,
		baseProfile: null,
		bbox: null,
		begin: null,
		bias: number,
		by: null,
		calcMode: null,
		capHeight: number,
		className: spaceSeparated,
		clip: null,
		clipPath: null,
		clipPathUnits: null,
		clipRule: null,
		color: null,
		colorInterpolation: null,
		colorInterpolationFilters: null,
		colorProfile: null,
		colorRendering: null,
		content: null,
		contentScriptType: null,
		contentStyleType: null,
		crossOrigin: null,
		cursor: null,
		cx: null,
		cy: null,
		d: null,
		dataType: null,
		defaultAction: null,
		descent: number,
		diffuseConstant: number,
		direction: null,
		display: null,
		dur: null,
		divisor: number,
		dominantBaseline: null,
		download: boolean,
		dx: null,
		dy: null,
		edgeMode: null,
		editable: null,
		elevation: number,
		enableBackground: null,
		end: null,
		event: null,
		exponent: number,
		externalResourcesRequired: null,
		fill: null,
		fillOpacity: number,
		fillRule: null,
		filter: null,
		filterRes: null,
		filterUnits: null,
		floodColor: null,
		floodOpacity: null,
		focusable: null,
		focusHighlight: null,
		fontFamily: null,
		fontSize: null,
		fontSizeAdjust: null,
		fontStretch: null,
		fontStyle: null,
		fontVariant: null,
		fontWeight: null,
		format: null,
		fr: null,
		from: null,
		fx: null,
		fy: null,
		g1: commaSeparated,
		g2: commaSeparated,
		glyphName: commaSeparated,
		glyphOrientationHorizontal: null,
		glyphOrientationVertical: null,
		glyphRef: null,
		gradientTransform: null,
		gradientUnits: null,
		handler: null,
		hanging: number,
		hatchContentUnits: null,
		hatchUnits: null,
		height: null,
		href: null,
		hrefLang: null,
		horizAdvX: number,
		horizOriginX: number,
		horizOriginY: number,
		id: null,
		ideographic: number,
		imageRendering: null,
		initialVisibility: null,
		in: null,
		in2: null,
		intercept: number,
		k: number,
		k1: number,
		k2: number,
		k3: number,
		k4: number,
		kernelMatrix: commaOrSpaceSeparated,
		kernelUnitLength: null,
		keyPoints: null,
		keySplines: null,
		keyTimes: null,
		kerning: null,
		lang: null,
		lengthAdjust: null,
		letterSpacing: null,
		lightingColor: null,
		limitingConeAngle: number,
		local: null,
		markerEnd: null,
		markerMid: null,
		markerStart: null,
		markerHeight: null,
		markerUnits: null,
		markerWidth: null,
		mask: null,
		maskContentUnits: null,
		maskUnits: null,
		mathematical: null,
		max: null,
		media: null,
		mediaCharacterEncoding: null,
		mediaContentEncodings: null,
		mediaSize: number,
		mediaTime: null,
		method: null,
		min: null,
		mode: null,
		name: null,
		navDown: null,
		navDownLeft: null,
		navDownRight: null,
		navLeft: null,
		navNext: null,
		navPrev: null,
		navRight: null,
		navUp: null,
		navUpLeft: null,
		navUpRight: null,
		numOctaves: null,
		observer: null,
		offset: null,
		onAbort: null,
		onActivate: null,
		onAfterPrint: null,
		onBeforePrint: null,
		onBegin: null,
		onCancel: null,
		onCanPlay: null,
		onCanPlayThrough: null,
		onChange: null,
		onClick: null,
		onClose: null,
		onCopy: null,
		onCueChange: null,
		onCut: null,
		onDblClick: null,
		onDrag: null,
		onDragEnd: null,
		onDragEnter: null,
		onDragExit: null,
		onDragLeave: null,
		onDragOver: null,
		onDragStart: null,
		onDrop: null,
		onDurationChange: null,
		onEmptied: null,
		onEnd: null,
		onEnded: null,
		onError: null,
		onFocus: null,
		onFocusIn: null,
		onFocusOut: null,
		onHashChange: null,
		onInput: null,
		onInvalid: null,
		onKeyDown: null,
		onKeyPress: null,
		onKeyUp: null,
		onLoad: null,
		onLoadedData: null,
		onLoadedMetadata: null,
		onLoadStart: null,
		onMessage: null,
		onMouseDown: null,
		onMouseEnter: null,
		onMouseLeave: null,
		onMouseMove: null,
		onMouseOut: null,
		onMouseOver: null,
		onMouseUp: null,
		onMouseWheel: null,
		onOffline: null,
		onOnline: null,
		onPageHide: null,
		onPageShow: null,
		onPaste: null,
		onPause: null,
		onPlay: null,
		onPlaying: null,
		onPopState: null,
		onProgress: null,
		onRateChange: null,
		onRepeat: null,
		onReset: null,
		onResize: null,
		onScroll: null,
		onSeeked: null,
		onSeeking: null,
		onSelect: null,
		onShow: null,
		onStalled: null,
		onStorage: null,
		onSubmit: null,
		onSuspend: null,
		onTimeUpdate: null,
		onToggle: null,
		onUnload: null,
		onVolumeChange: null,
		onWaiting: null,
		onZoom: null,
		opacity: null,
		operator: null,
		order: null,
		orient: null,
		orientation: null,
		origin: null,
		overflow: null,
		overlay: null,
		overlinePosition: number,
		overlineThickness: number,
		paintOrder: null,
		panose1: null,
		path: null,
		pathLength: number,
		patternContentUnits: null,
		patternTransform: null,
		patternUnits: null,
		phase: null,
		ping: spaceSeparated,
		pitch: null,
		playbackOrder: null,
		pointerEvents: null,
		points: null,
		pointsAtX: number,
		pointsAtY: number,
		pointsAtZ: number,
		preserveAlpha: null,
		preserveAspectRatio: null,
		primitiveUnits: null,
		propagate: null,
		property: commaOrSpaceSeparated,
		r: null,
		radius: null,
		referrerPolicy: null,
		refX: null,
		refY: null,
		rel: commaOrSpaceSeparated,
		rev: commaOrSpaceSeparated,
		renderingIntent: null,
		repeatCount: null,
		repeatDur: null,
		requiredExtensions: commaOrSpaceSeparated,
		requiredFeatures: commaOrSpaceSeparated,
		requiredFonts: commaOrSpaceSeparated,
		requiredFormats: commaOrSpaceSeparated,
		resource: null,
		restart: null,
		result: null,
		rotate: null,
		rx: null,
		ry: null,
		scale: null,
		seed: null,
		shapeRendering: null,
		side: null,
		slope: null,
		snapshotTime: null,
		specularConstant: number,
		specularExponent: number,
		spreadMethod: null,
		spacing: null,
		startOffset: null,
		stdDeviation: null,
		stemh: null,
		stemv: null,
		stitchTiles: null,
		stopColor: null,
		stopOpacity: null,
		strikethroughPosition: number,
		strikethroughThickness: number,
		string: null,
		stroke: null,
		strokeDashArray: commaOrSpaceSeparated,
		strokeDashOffset: null,
		strokeLineCap: null,
		strokeLineJoin: null,
		strokeMiterLimit: number,
		strokeOpacity: number,
		strokeWidth: null,
		style: null,
		surfaceScale: number,
		syncBehavior: null,
		syncBehaviorDefault: null,
		syncMaster: null,
		syncTolerance: null,
		syncToleranceDefault: null,
		systemLanguage: commaOrSpaceSeparated,
		tabIndex: number,
		tableValues: null,
		target: null,
		targetX: number,
		targetY: number,
		textAnchor: null,
		textDecoration: null,
		textRendering: null,
		textLength: null,
		timelineBegin: null,
		title: null,
		transformBehavior: null,
		type: null,
		typeOf: commaOrSpaceSeparated,
		to: null,
		transform: null,
		transformOrigin: null,
		u1: null,
		u2: null,
		underlinePosition: number,
		underlineThickness: number,
		unicode: null,
		unicodeBidi: null,
		unicodeRange: null,
		unitsPerEm: number,
		values: null,
		vAlphabetic: number,
		vMathematical: number,
		vectorEffect: null,
		vHanging: number,
		vIdeographic: number,
		version: null,
		vertAdvY: number,
		vertOriginX: number,
		vertOriginY: number,
		viewBox: null,
		viewTarget: null,
		visibility: null,
		width: null,
		widths: null,
		wordSpacing: null,
		writingMode: null,
		x: null,
		x1: null,
		x2: null,
		xChannelSelector: null,
		xHeight: number,
		y: null,
		y1: null,
		y2: null,
		yChannelSelector: null,
		z: null,
		zoomAndPan: null
	},
	space: "svg",
	transform: caseSensitiveTransform
});

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/xlink.js
const xlink = create({
	properties: {
		xLinkActuate: null,
		xLinkArcRole: null,
		xLinkHref: null,
		xLinkRole: null,
		xLinkShow: null,
		xLinkTitle: null,
		xLinkType: null
	},
	space: "xlink",
	transform(_$2, property) {
		return "xlink:" + property.slice(5).toLowerCase();
	}
});

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/xmlns.js
const xmlns = create({
	attributes: { xmlnsxlink: "xmlns:xlink" },
	properties: {
		xmlnsXLink: null,
		xmlns: null
	},
	space: "xmlns",
	transform: caseInsensitiveTransform
});

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/xml.js
const xml = create({
	properties: {
		xmlBase: null,
		xmlLang: null,
		xmlSpace: null
	},
	space: "xml",
	transform(_$2, property) {
		return "xml:" + property.slice(3).toLowerCase();
	}
});

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/hast-to-react.js
/**
* Special cases for React (`Record<string, string>`).
*
* `hast` is close to `React` but differs in a couple of cases.
* To get a React property from a hast property,
* check if it is in `hastToReact`.
* If it is, use the corresponding value;
* otherwise, use the hast property.
*
* @type {Record<string, string>}
*/
const hastToReact = {
	classId: "classID",
	dataType: "datatype",
	itemId: "itemID",
	strokeDashArray: "strokeDasharray",
	strokeDashOffset: "strokeDashoffset",
	strokeLineCap: "strokeLinecap",
	strokeLineJoin: "strokeLinejoin",
	strokeMiterLimit: "strokeMiterlimit",
	typeOf: "typeof",
	xLinkActuate: "xlinkActuate",
	xLinkArcRole: "xlinkArcrole",
	xLinkHref: "xlinkHref",
	xLinkRole: "xlinkRole",
	xLinkShow: "xlinkShow",
	xLinkTitle: "xlinkTitle",
	xLinkType: "xlinkType",
	xmlnsXLink: "xmlnsXlink"
};

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/lib/find.js
const cap = /[A-Z]/g;
const dash = /-[a-z]/g;
const valid = /^data[-\w.:]+$/i;
/**
* Look up info on a property.
*
* In most cases the given `schema` contains info on the property.
* All standard,
* most legacy,
* and some non-standard properties are supported.
* For these cases,
* the returned `Info` has hints about the value of the property.
*
* `name` can also be a valid data attribute or property,
* in which case an `Info` object with the correctly cased `attribute` and
* `property` is returned.
*
* `name` can be an unknown attribute,
* in which case an `Info` object with `attribute` and `property` set to the
* given name is returned.
* It is not recommended to provide unsupported legacy or recently specced
* properties.
*
*
* @param {Schema} schema
*   Schema;
*   either the `html` or `svg` export.
* @param {string} value
*   An attribute-like or property-like name;
*   it will be passed through `normalize` to hopefully find the correct info.
* @returns {Info}
*   Info.
*/
function find(schema, value) {
	const normal = normalize(value);
	let property = value;
	let Type = Info;
	if (normal in schema.normal) {
		return schema.property[schema.normal[normal]];
	}
	if (normal.length > 4 && normal.slice(0, 4) === "data" && valid.test(value)) {
		if (value.charAt(4) === "-") {
			const rest = value.slice(5).replace(dash, camelcase);
			property = "data" + rest.charAt(0).toUpperCase() + rest.slice(1);
		} else {
			const rest = value.slice(4);
			if (!dash.test(rest)) {
				let dashes = rest.replace(cap, kebab);
				if (dashes.charAt(0) !== "-") {
					dashes = "-" + dashes;
				}
				value = "data" + dashes;
			}
		}
		Type = DefinedInfo;
	}
	return new Type(property, value);
}
/**
* @param {string} $0
*   Value.
* @returns {string}
*   Kebab.
*/
function kebab($0) {
	return "-" + $0.toLowerCase();
}
/**
* @param {string} $0
*   Value.
* @returns {string}
*   Camel.
*/
function camelcase($0) {
	return $0.charAt(1).toUpperCase();
}

//#endregion
//#region ../../node_modules/.bun/property-information@7.1.0/node_modules/property-information/index.js
const html = merge([
	aria,
	html$3,
	xlink,
	xmlns,
	xml
], "html");
const svg = merge([
	aria,
	svg$1,
	xlink,
	xmlns,
	xml
], "svg");

//#endregion
//#region ../../node_modules/.bun/zwitch@2.0.4/node_modules/zwitch/index.js
/**
* @callback Handler
*   Handle a value, with a certain ID field set to a certain value.
*   The ID field is passed to `zwitch`, and it’s value is this function’s
*   place on the `handlers` record.
* @param {...any} parameters
*   Arbitrary parameters passed to the zwitch.
*   The first will be an object with a certain ID field set to a certain value.
* @returns {any}
*   Anything!
*/
/**
* @callback UnknownHandler
*   Handle values that do have a certain ID field, but it’s set to a value
*   that is not listed in the `handlers` record.
* @param {unknown} value
*   An object with a certain ID field set to an unknown value.
* @param {...any} rest
*   Arbitrary parameters passed to the zwitch.
* @returns {any}
*   Anything!
*/
/**
* @callback InvalidHandler
*   Handle values that do not have a certain ID field.
* @param {unknown} value
*   Any unknown value.
* @param {...any} rest
*   Arbitrary parameters passed to the zwitch.
* @returns {void|null|undefined|never}
*   This should crash or return nothing.
*/
/**
* @template {InvalidHandler} [Invalid=InvalidHandler]
* @template {UnknownHandler} [Unknown=UnknownHandler]
* @template {Record<string, Handler>} [Handlers=Record<string, Handler>]
* @typedef Options
*   Configuration (required).
* @property {Invalid} [invalid]
*   Handler to use for invalid values.
* @property {Unknown} [unknown]
*   Handler to use for unknown values.
* @property {Handlers} [handlers]
*   Handlers to use.
*/
const own$2 = {}.hasOwnProperty;
/**
* Handle values based on a field.
*
* @template {InvalidHandler} [Invalid=InvalidHandler]
* @template {UnknownHandler} [Unknown=UnknownHandler]
* @template {Record<string, Handler>} [Handlers=Record<string, Handler>]
* @param {string} key
*   Field to switch on.
* @param {Options<Invalid, Unknown, Handlers>} [options]
*   Configuration (required).
* @returns {{unknown: Unknown, invalid: Invalid, handlers: Handlers, (...parameters: Parameters<Handlers[keyof Handlers]>): ReturnType<Handlers[keyof Handlers]>, (...parameters: Parameters<Unknown>): ReturnType<Unknown>}}
*/
function zwitch(key$1, options) {
	const settings = options || {};
	/**
	* Handle one value.
	*
	* Based on the bound `key`, a respective handler will be called.
	* If `value` is not an object, or doesn’t have a `key` property, the special
	* “invalid” handler will be called.
	* If `value` has an unknown `key`, the special “unknown” handler will be
	* called.
	*
	* All arguments, and the context object, are passed through to the handler,
	* and it’s result is returned.
	*
	* @this {unknown}
	*   Any context object.
	* @param {unknown} [value]
	*   Any value.
	* @param {...unknown} parameters
	*   Arbitrary parameters passed to the zwitch.
	* @property {Handler} invalid
	*   Handle for values that do not have a certain ID field.
	* @property {Handler} unknown
	*   Handle values that do have a certain ID field, but it’s set to a value
	*   that is not listed in the `handlers` record.
	* @property {Handlers} handlers
	*   Record of handlers.
	* @returns {unknown}
	*   Anything.
	*/
	function one$1(value, ...parameters) {
		/** @type {Handler|undefined} */
		let fn = one$1.invalid;
		const handlers = one$1.handlers;
		if (value && own$2.call(value, key$1)) {
			const id = String(value[key$1]);
			fn = own$2.call(handlers, id) ? handlers[id] : one$1.unknown;
		}
		if (fn) {
			return fn.call(this, value, ...parameters);
		}
	}
	one$1.handlers = settings.handlers || {};
	one$1.invalid = settings.invalid;
	one$1.unknown = settings.unknown;
	return one$1;
}

//#endregion
//#region ../../node_modules/.bun/stringify-entities@4.0.4/node_modules/stringify-entities/lib/core.js
/**
* @typedef CoreOptions
* @property {ReadonlyArray<string>} [subset=[]]
*   Whether to only escape the given subset of characters.
* @property {boolean} [escapeOnly=false]
*   Whether to only escape possibly dangerous characters.
*   Those characters are `"`, `&`, `'`, `<`, `>`, and `` ` ``.
*
* @typedef FormatOptions
* @property {(code: number, next: number, options: CoreWithFormatOptions) => string} format
*   Format strategy.
*
* @typedef {CoreOptions & FormatOptions & import('./util/format-smart.js').FormatSmartOptions} CoreWithFormatOptions
*/
const defaultSubsetRegex = /["&'<>`]/g;
const surrogatePairsRegex = /[\uD800-\uDBFF][\uDC00-\uDFFF]/g;
const controlCharactersRegex = /[\x01-\t\v\f\x0E-\x1F\x7F\x81\x8D\x8F\x90\x9D\xA0-\uFFFF]/g;
const regexEscapeRegex = /[|\\{}()[\]^$+*?.]/g;
/** @type {WeakMap<ReadonlyArray<string>, RegExp>} */
const subsetToRegexCache = new WeakMap();
/**
* Encode certain characters in `value`.
*
* @param {string} value
* @param {CoreWithFormatOptions} options
* @returns {string}
*/
function core(value, options) {
	value = value.replace(options.subset ? charactersToExpressionCached(options.subset) : defaultSubsetRegex, basic);
	if (options.subset || options.escapeOnly) {
		return value;
	}
	return value.replace(surrogatePairsRegex, surrogate).replace(controlCharactersRegex, basic);
	/**
	* @param {string} pair
	* @param {number} index
	* @param {string} all
	*/
	function surrogate(pair, index, all$1) {
		return options.format((pair.charCodeAt(0) - 55296) * 1024 + pair.charCodeAt(1) - 56320 + 65536, all$1.charCodeAt(index + 2), options);
	}
	/**
	* @param {string} character
	* @param {number} index
	* @param {string} all
	*/
	function basic(character, index, all$1) {
		return options.format(character.charCodeAt(0), all$1.charCodeAt(index + 1), options);
	}
}
/**
* A wrapper function that caches the result of `charactersToExpression` with a WeakMap.
* This can improve performance when tooling calls `charactersToExpression` repeatedly
* with the same subset.
*
* @param {ReadonlyArray<string>} subset
* @returns {RegExp}
*/
function charactersToExpressionCached(subset) {
	let cached = subsetToRegexCache.get(subset);
	if (!cached) {
		cached = charactersToExpression(subset);
		subsetToRegexCache.set(subset, cached);
	}
	return cached;
}
/**
* @param {ReadonlyArray<string>} subset
* @returns {RegExp}
*/
function charactersToExpression(subset) {
	/** @type {Array<string>} */
	const groups = [];
	let index = -1;
	while (++index < subset.length) {
		groups.push(subset[index].replace(regexEscapeRegex, "\\$&"));
	}
	return new RegExp("(?:" + groups.join("|") + ")", "g");
}

//#endregion
//#region ../../node_modules/.bun/stringify-entities@4.0.4/node_modules/stringify-entities/lib/util/to-hexadecimal.js
const hexadecimalRegex = /[\dA-Fa-f]/;
/**
* Configurable ways to encode characters as hexadecimal references.
*
* @param {number} code
* @param {number} next
* @param {boolean|undefined} omit
* @returns {string}
*/
function toHexadecimal(code, next, omit) {
	const value = "&#x" + code.toString(16).toUpperCase();
	return omit && next && !hexadecimalRegex.test(String.fromCharCode(next)) ? value : value + ";";
}

//#endregion
//#region ../../node_modules/.bun/stringify-entities@4.0.4/node_modules/stringify-entities/lib/util/to-decimal.js
const decimalRegex = /\d/;
/**
* Configurable ways to encode characters as decimal references.
*
* @param {number} code
* @param {number} next
* @param {boolean|undefined} omit
* @returns {string}
*/
function toDecimal(code, next, omit) {
	const value = "&#" + String(code);
	return omit && next && !decimalRegex.test(String.fromCharCode(next)) ? value : value + ";";
}

//#endregion
//#region ../../node_modules/.bun/character-entities-legacy@3.0.0/node_modules/character-entities-legacy/index.js
/**
* List of legacy HTML named character references that don’t need a trailing semicolon.
*
* @type {Array<string>}
*/
const characterEntitiesLegacy = [
	"AElig",
	"AMP",
	"Aacute",
	"Acirc",
	"Agrave",
	"Aring",
	"Atilde",
	"Auml",
	"COPY",
	"Ccedil",
	"ETH",
	"Eacute",
	"Ecirc",
	"Egrave",
	"Euml",
	"GT",
	"Iacute",
	"Icirc",
	"Igrave",
	"Iuml",
	"LT",
	"Ntilde",
	"Oacute",
	"Ocirc",
	"Ograve",
	"Oslash",
	"Otilde",
	"Ouml",
	"QUOT",
	"REG",
	"THORN",
	"Uacute",
	"Ucirc",
	"Ugrave",
	"Uuml",
	"Yacute",
	"aacute",
	"acirc",
	"acute",
	"aelig",
	"agrave",
	"amp",
	"aring",
	"atilde",
	"auml",
	"brvbar",
	"ccedil",
	"cedil",
	"cent",
	"copy",
	"curren",
	"deg",
	"divide",
	"eacute",
	"ecirc",
	"egrave",
	"eth",
	"euml",
	"frac12",
	"frac14",
	"frac34",
	"gt",
	"iacute",
	"icirc",
	"iexcl",
	"igrave",
	"iquest",
	"iuml",
	"laquo",
	"lt",
	"macr",
	"micro",
	"middot",
	"nbsp",
	"not",
	"ntilde",
	"oacute",
	"ocirc",
	"ograve",
	"ordf",
	"ordm",
	"oslash",
	"otilde",
	"ouml",
	"para",
	"plusmn",
	"pound",
	"quot",
	"raquo",
	"reg",
	"sect",
	"shy",
	"sup1",
	"sup2",
	"sup3",
	"szlig",
	"thorn",
	"times",
	"uacute",
	"ucirc",
	"ugrave",
	"uml",
	"uuml",
	"yacute",
	"yen",
	"yuml"
];

//#endregion
//#region ../../node_modules/.bun/character-entities-html4@2.1.0/node_modules/character-entities-html4/index.js
/**
* Map of named character references from HTML 4.
*
* @type {Record<string, string>}
*/
const characterEntitiesHtml4 = {
	nbsp: "\xA0",
	iexcl: "¡",
	cent: "¢",
	pound: "£",
	curren: "¤",
	yen: "¥",
	brvbar: "¦",
	sect: "§",
	uml: "¨",
	copy: "©",
	ordf: "ª",
	laquo: "«",
	not: "¬",
	shy: "­",
	reg: "®",
	macr: "¯",
	deg: "°",
	plusmn: "±",
	sup2: "²",
	sup3: "³",
	acute: "´",
	micro: "µ",
	para: "¶",
	middot: "·",
	cedil: "¸",
	sup1: "¹",
	ordm: "º",
	raquo: "»",
	frac14: "¼",
	frac12: "½",
	frac34: "¾",
	iquest: "¿",
	Agrave: "À",
	Aacute: "Á",
	Acirc: "Â",
	Atilde: "Ã",
	Auml: "Ä",
	Aring: "Å",
	AElig: "Æ",
	Ccedil: "Ç",
	Egrave: "È",
	Eacute: "É",
	Ecirc: "Ê",
	Euml: "Ë",
	Igrave: "Ì",
	Iacute: "Í",
	Icirc: "Î",
	Iuml: "Ï",
	ETH: "Ð",
	Ntilde: "Ñ",
	Ograve: "Ò",
	Oacute: "Ó",
	Ocirc: "Ô",
	Otilde: "Õ",
	Ouml: "Ö",
	times: "×",
	Oslash: "Ø",
	Ugrave: "Ù",
	Uacute: "Ú",
	Ucirc: "Û",
	Uuml: "Ü",
	Yacute: "Ý",
	THORN: "Þ",
	szlig: "ß",
	agrave: "à",
	aacute: "á",
	acirc: "â",
	atilde: "ã",
	auml: "ä",
	aring: "å",
	aelig: "æ",
	ccedil: "ç",
	egrave: "è",
	eacute: "é",
	ecirc: "ê",
	euml: "ë",
	igrave: "ì",
	iacute: "í",
	icirc: "î",
	iuml: "ï",
	eth: "ð",
	ntilde: "ñ",
	ograve: "ò",
	oacute: "ó",
	ocirc: "ô",
	otilde: "õ",
	ouml: "ö",
	divide: "÷",
	oslash: "ø",
	ugrave: "ù",
	uacute: "ú",
	ucirc: "û",
	uuml: "ü",
	yacute: "ý",
	thorn: "þ",
	yuml: "ÿ",
	fnof: "ƒ",
	Alpha: "Α",
	Beta: "Β",
	Gamma: "Γ",
	Delta: "Δ",
	Epsilon: "Ε",
	Zeta: "Ζ",
	Eta: "Η",
	Theta: "Θ",
	Iota: "Ι",
	Kappa: "Κ",
	Lambda: "Λ",
	Mu: "Μ",
	Nu: "Ν",
	Xi: "Ξ",
	Omicron: "Ο",
	Pi: "Π",
	Rho: "Ρ",
	Sigma: "Σ",
	Tau: "Τ",
	Upsilon: "Υ",
	Phi: "Φ",
	Chi: "Χ",
	Psi: "Ψ",
	Omega: "Ω",
	alpha: "α",
	beta: "β",
	gamma: "γ",
	delta: "δ",
	epsilon: "ε",
	zeta: "ζ",
	eta: "η",
	theta: "θ",
	iota: "ι",
	kappa: "κ",
	lambda: "λ",
	mu: "μ",
	nu: "ν",
	xi: "ξ",
	omicron: "ο",
	pi: "π",
	rho: "ρ",
	sigmaf: "ς",
	sigma: "σ",
	tau: "τ",
	upsilon: "υ",
	phi: "φ",
	chi: "χ",
	psi: "ψ",
	omega: "ω",
	thetasym: "ϑ",
	upsih: "ϒ",
	piv: "ϖ",
	bull: "•",
	hellip: "…",
	prime: "′",
	Prime: "″",
	oline: "‾",
	frasl: "⁄",
	weierp: "℘",
	image: "ℑ",
	real: "ℜ",
	trade: "™",
	alefsym: "ℵ",
	larr: "←",
	uarr: "↑",
	rarr: "→",
	darr: "↓",
	harr: "↔",
	crarr: "↵",
	lArr: "⇐",
	uArr: "⇑",
	rArr: "⇒",
	dArr: "⇓",
	hArr: "⇔",
	forall: "∀",
	part: "∂",
	exist: "∃",
	empty: "∅",
	nabla: "∇",
	isin: "∈",
	notin: "∉",
	ni: "∋",
	prod: "∏",
	sum: "∑",
	minus: "−",
	lowast: "∗",
	radic: "√",
	prop: "∝",
	infin: "∞",
	ang: "∠",
	and: "∧",
	or: "∨",
	cap: "∩",
	cup: "∪",
	int: "∫",
	there4: "∴",
	sim: "∼",
	cong: "≅",
	asymp: "≈",
	ne: "≠",
	equiv: "≡",
	le: "≤",
	ge: "≥",
	sub: "⊂",
	sup: "⊃",
	nsub: "⊄",
	sube: "⊆",
	supe: "⊇",
	oplus: "⊕",
	otimes: "⊗",
	perp: "⊥",
	sdot: "⋅",
	lceil: "⌈",
	rceil: "⌉",
	lfloor: "⌊",
	rfloor: "⌋",
	lang: "〈",
	rang: "〉",
	loz: "◊",
	spades: "♠",
	clubs: "♣",
	hearts: "♥",
	diams: "♦",
	quot: "\"",
	amp: "&",
	lt: "<",
	gt: ">",
	OElig: "Œ",
	oelig: "œ",
	Scaron: "Š",
	scaron: "š",
	Yuml: "Ÿ",
	circ: "ˆ",
	tilde: "˜",
	ensp: " ",
	emsp: " ",
	thinsp: " ",
	zwnj: "‌",
	zwj: "‍",
	lrm: "‎",
	rlm: "‏",
	ndash: "–",
	mdash: "—",
	lsquo: "‘",
	rsquo: "’",
	sbquo: "‚",
	ldquo: "“",
	rdquo: "”",
	bdquo: "„",
	dagger: "†",
	Dagger: "‡",
	permil: "‰",
	lsaquo: "‹",
	rsaquo: "›",
	euro: "€"
};

//#endregion
//#region ../../node_modules/.bun/stringify-entities@4.0.4/node_modules/stringify-entities/lib/constant/dangerous.js
/**
* List of legacy (that don’t need a trailing `;`) named references which could,
* depending on what follows them, turn into a different meaning
*
* @type {Array<string>}
*/
const dangerous = [
	"cent",
	"copy",
	"divide",
	"gt",
	"lt",
	"not",
	"para",
	"times"
];

//#endregion
//#region ../../node_modules/.bun/stringify-entities@4.0.4/node_modules/stringify-entities/lib/util/to-named.js
const own$1 = {}.hasOwnProperty;
/**
* `characterEntitiesHtml4` but inverted.
*
* @type {Record<string, string>}
*/
const characters = {};
/** @type {string} */
let key;
for (key in characterEntitiesHtml4) {
	if (own$1.call(characterEntitiesHtml4, key)) {
		characters[characterEntitiesHtml4[key]] = key;
	}
}
const notAlphanumericRegex = /[^\dA-Za-z]/;
/**
* Configurable ways to encode characters as named references.
*
* @param {number} code
* @param {number} next
* @param {boolean|undefined} omit
* @param {boolean|undefined} attribute
* @returns {string}
*/
function toNamed(code, next, omit, attribute) {
	const character = String.fromCharCode(code);
	if (own$1.call(characters, character)) {
		const name = characters[character];
		const value = "&" + name;
		if (omit && characterEntitiesLegacy.includes(name) && !dangerous.includes(name) && (!attribute || next && next !== 61 && notAlphanumericRegex.test(String.fromCharCode(next)))) {
			return value;
		}
		return value + ";";
	}
	return "";
}

//#endregion
//#region ../../node_modules/.bun/stringify-entities@4.0.4/node_modules/stringify-entities/lib/util/format-smart.js
/**
* Configurable ways to encode a character yielding pretty or small results.
*
* @param {number} code
* @param {number} next
* @param {FormatSmartOptions} options
* @returns {string}
*/
function formatSmart(code, next, options) {
	let numeric = toHexadecimal(code, next, options.omitOptionalSemicolons);
	/** @type {string|undefined} */
	let named;
	if (options.useNamedReferences || options.useShortestReferences) {
		named = toNamed(code, next, options.omitOptionalSemicolons, options.attribute);
	}
	if ((options.useShortestReferences || !named) && options.useShortestReferences) {
		const decimal = toDecimal(code, next, options.omitOptionalSemicolons);
		if (decimal.length < numeric.length) {
			numeric = decimal;
		}
	}
	return named && (!options.useShortestReferences || named.length < numeric.length) ? named : numeric;
}

//#endregion
//#region ../../node_modules/.bun/stringify-entities@4.0.4/node_modules/stringify-entities/lib/util/format-basic.js
/**
* The smallest way to encode a character.
*
* @param {number} code
* @returns {string}
*/
function formatBasic(code) {
	return "&#x" + code.toString(16).toUpperCase() + ";";
}

//#endregion
//#region ../../node_modules/.bun/stringify-entities@4.0.4/node_modules/stringify-entities/lib/index.js
/**
* Encode special characters in `value`.
*
* @param {string} value
*   Value to encode.
* @param {Options} [options]
*   Configuration.
* @returns {string}
*   Encoded value.
*/
function stringifyEntities(value, options) {
	return core(value, Object.assign({ format: formatSmart }, options));
}
/**
* Encode special characters in `value` as hexadecimals.
*
* @param {string} value
*   Value to encode.
* @param {LightOptions} [options]
*   Configuration.
* @returns {string}
*   Encoded value.
*/
function stringifyEntitiesLight(value, options) {
	return core(value, Object.assign({ format: formatBasic }, options));
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/handle/comment.js
const htmlCommentRegex = /^>|^->|<!--|-->|--!>|<!-$/g;
const bogusCommentEntitySubset = [">"];
const commentEntitySubset = ["<", ">"];
/**
* Serialize a comment.
*
* @param {Comment} node
*   Node to handle.
* @param {number | undefined} _1
*   Index of `node` in `parent.
* @param {Parents | undefined} _2
*   Parent of `node`.
* @param {State} state
*   Info passed around about the current state.
* @returns {string}
*   Serialized node.
*/
function comment(node, _1, _2, state) {
	return state.settings.bogusComments ? "<?" + stringifyEntities(node.value, Object.assign({}, state.settings.characterReferences, { subset: bogusCommentEntitySubset })) + ">" : "<!--" + node.value.replace(htmlCommentRegex, encode) + "-->";
	/**
	* @param {string} $0
	*/
	function encode($0) {
		return stringifyEntities($0, Object.assign({}, state.settings.characterReferences, { subset: commentEntitySubset }));
	}
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/handle/doctype.js
/**
* @import {Doctype, Parents} from 'hast'
* @import {State} from '../index.js'
*/
/**
* Serialize a doctype.
*
* @param {Doctype} _1
*   Node to handle.
* @param {number | undefined} _2
*   Index of `node` in `parent.
* @param {Parents | undefined} _3
*   Parent of `node`.
* @param {State} state
*   Info passed around about the current state.
* @returns {string}
*   Serialized node.
*/
function doctype(_1, _2, _3, state) {
	return "<!" + (state.settings.upperDoctype ? "DOCTYPE" : "doctype") + (state.settings.tightDoctype ? "" : " ") + "html>";
}

//#endregion
//#region ../../node_modules/.bun/ccount@2.0.1/node_modules/ccount/index.js
/**
* Count how often a character (or substring) is used in a string.
*
* @param {string} value
*   Value to search in.
* @param {string} character
*   Character (or substring) to look for.
* @return {number}
*   Number of times `character` occurred in `value`.
*/
function ccount(value, character) {
	const source = String(value);
	if (typeof character !== "string") {
		throw new TypeError("Expected character");
	}
	let count = 0;
	let index = source.indexOf(character);
	while (index !== -1) {
		count++;
		index = source.indexOf(character, index + character.length);
	}
	return count;
}

//#endregion
//#region ../../node_modules/.bun/comma-separated-tokens@2.0.3/node_modules/comma-separated-tokens/index.js
/**
* @typedef Options
*   Configuration for `stringify`.
* @property {boolean} [padLeft=true]
*   Whether to pad a space before a token.
* @property {boolean} [padRight=false]
*   Whether to pad a space after a token.
*/
/**
* @typedef {Options} StringifyOptions
*   Please use `StringifyOptions` instead.
*/
/**
* Parse comma-separated tokens to an array.
*
* @param {string} value
*   Comma-separated tokens.
* @returns {Array<string>}
*   List of tokens.
*/
function parse$1(value) {
	/** @type {Array<string>} */
	const tokens = [];
	const input = String(value || "");
	let index = input.indexOf(",");
	let start = 0;
	/** @type {boolean} */
	let end = false;
	while (!end) {
		if (index === -1) {
			index = input.length;
			end = true;
		}
		const token$1 = input.slice(start, index).trim();
		if (token$1 || !end) {
			tokens.push(token$1);
		}
		start = index + 1;
		index = input.indexOf(",", start);
	}
	return tokens;
}
/**
* Serialize an array of strings or numbers to comma-separated tokens.
*
* @param {Array<string|number>} values
*   List of tokens.
* @param {Options} [options]
*   Configuration for `stringify` (optional).
* @returns {string}
*   Comma-separated tokens.
*/
function stringify$1(values, options) {
	const settings = options || {};
	const input = values[values.length - 1] === "" ? [...values, ""] : values;
	return input.join((settings.padRight ? " " : "") + "," + (settings.padLeft === false ? "" : " ")).trim();
}

//#endregion
//#region ../../node_modules/.bun/space-separated-tokens@2.0.2/node_modules/space-separated-tokens/index.js
/**
* Parse space-separated tokens to an array of strings.
*
* @param {string} value
*   Space-separated tokens.
* @returns {Array<string>}
*   List of tokens.
*/
function parse(value) {
	const input = String(value || "").trim();
	return input ? input.split(/[ \t\n\r\f]+/g) : [];
}
/**
* Serialize an array of strings as space separated-tokens.
*
* @param {Array<string|number>} values
*   List of tokens.
* @returns {string}
*   Space-separated tokens.
*/
function stringify$2(values) {
	return values.join(" ").trim();
}

//#endregion
//#region ../../node_modules/.bun/hast-util-whitespace@3.0.0/node_modules/hast-util-whitespace/lib/index.js
/**
* @typedef {import('hast').Nodes} Nodes
*/
const re$1 = /[ \t\n\f\r]/g;
/**
* Check if the given value is *inter-element whitespace*.
*
* @param {Nodes | string} thing
*   Thing to check (`Node` or `string`).
* @returns {boolean}
*   Whether the `value` is inter-element whitespace (`boolean`): consisting of
*   zero or more of space, tab (`\t`), line feed (`\n`), carriage return
*   (`\r`), or form feed (`\f`); if a node is passed it must be a `Text` node,
*   whose `value` field is checked.
*/
function whitespace(thing) {
	return typeof thing === "object" ? thing.type === "text" ? empty(thing.value) : false : empty(thing);
}
/**
* @param {string} value
* @returns {boolean}
*/
function empty(value) {
	return value.replace(re$1, "") === "";
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/omission/util/siblings.js
const siblingAfter = siblings(1);
const siblingBefore = siblings(-1);
/** @type {Array<RootContent>} */
const emptyChildren$1 = [];
/**
* Factory to check siblings in a direction.
*
* @param {number} increment
*/
function siblings(increment$1) {
	return sibling;
	/**
	* Find applicable siblings in a direction.
	*
	* @template {Parents} Parent
	*   Parent type.
	* @param {Parent | undefined} parent
	*   Parent.
	* @param {number | undefined} index
	*   Index of child in `parent`.
	* @param {boolean | undefined} [includeWhitespace=false]
	*   Whether to include whitespace (default: `false`).
	* @returns {Parent extends {children: Array<infer Child>} ? Child | undefined : never}
	*   Child of parent.
	*/
	function sibling(parent, index, includeWhitespace) {
		const siblings$1 = parent ? parent.children : emptyChildren$1;
		let offset = (index || 0) + increment$1;
		let next = siblings$1[offset];
		if (!includeWhitespace) {
			while (next && whitespace(next)) {
				offset += increment$1;
				next = siblings$1[offset];
			}
		}
		return next;
	}
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/omission/omission.js
/**
* @import {Element, Parents} from 'hast'
*/
/**
* @callback OmitHandle
*   Check if a tag can be omitted.
* @param {Element} element
*   Element to check.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether to omit a tag.
*
*/
const own = {}.hasOwnProperty;
/**
* Factory to check if a given node can have a tag omitted.
*
* @param {Record<string, OmitHandle>} handlers
*   Omission handlers, where each key is a tag name, and each value is the
*   corresponding handler.
* @returns {OmitHandle}
*   Whether to omit a tag of an element.
*/
function omission(handlers) {
	return omit;
	/**
	* Check if a given node can have a tag omitted.
	*
	* @type {OmitHandle}
	*/
	function omit(node, index, parent) {
		return own.call(handlers, node.tagName) && handlers[node.tagName](node, index, parent);
	}
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/omission/closing.js
const closing = omission({
	body: body$1,
	caption: headOrColgroupOrCaption,
	colgroup: headOrColgroupOrCaption,
	dd,
	dt,
	head: headOrColgroupOrCaption,
	html: html$2,
	li,
	optgroup,
	option,
	p,
	rp: rubyElement,
	rt: rubyElement,
	tbody: tbody$1,
	td: cells,
	tfoot,
	th: cells,
	thead,
	tr
});
/**
* Macro for `</head>`, `</colgroup>`, and `</caption>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function headOrColgroupOrCaption(_$2, index, parent) {
	const next = siblingAfter(parent, index, true);
	return !next || next.type !== "comment" && !(next.type === "text" && whitespace(next.value.charAt(0)));
}
/**
* Whether to omit `</html>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function html$2(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type !== "comment";
}
/**
* Whether to omit `</body>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function body$1(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type !== "comment";
}
/**
* Whether to omit `</p>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function p(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return next ? next.type === "element" && (next.tagName === "address" || next.tagName === "article" || next.tagName === "aside" || next.tagName === "blockquote" || next.tagName === "details" || next.tagName === "div" || next.tagName === "dl" || next.tagName === "fieldset" || next.tagName === "figcaption" || next.tagName === "figure" || next.tagName === "footer" || next.tagName === "form" || next.tagName === "h1" || next.tagName === "h2" || next.tagName === "h3" || next.tagName === "h4" || next.tagName === "h5" || next.tagName === "h6" || next.tagName === "header" || next.tagName === "hgroup" || next.tagName === "hr" || next.tagName === "main" || next.tagName === "menu" || next.tagName === "nav" || next.tagName === "ol" || next.tagName === "p" || next.tagName === "pre" || next.tagName === "section" || next.tagName === "table" || next.tagName === "ul") : !parent || !(parent.type === "element" && (parent.tagName === "a" || parent.tagName === "audio" || parent.tagName === "del" || parent.tagName === "ins" || parent.tagName === "map" || parent.tagName === "noscript" || parent.tagName === "video"));
}
/**
* Whether to omit `</li>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function li(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type === "element" && next.tagName === "li";
}
/**
* Whether to omit `</dt>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function dt(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return Boolean(next && next.type === "element" && (next.tagName === "dt" || next.tagName === "dd"));
}
/**
* Whether to omit `</dd>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function dd(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type === "element" && (next.tagName === "dt" || next.tagName === "dd");
}
/**
* Whether to omit `</rt>` or `</rp>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function rubyElement(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type === "element" && (next.tagName === "rp" || next.tagName === "rt");
}
/**
* Whether to omit `</optgroup>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function optgroup(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type === "element" && next.tagName === "optgroup";
}
/**
* Whether to omit `</option>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function option(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type === "element" && (next.tagName === "option" || next.tagName === "optgroup");
}
/**
* Whether to omit `</thead>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function thead(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return Boolean(next && next.type === "element" && (next.tagName === "tbody" || next.tagName === "tfoot"));
}
/**
* Whether to omit `</tbody>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function tbody$1(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type === "element" && (next.tagName === "tbody" || next.tagName === "tfoot");
}
/**
* Whether to omit `</tfoot>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function tfoot(_$2, index, parent) {
	return !siblingAfter(parent, index);
}
/**
* Whether to omit `</tr>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function tr(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type === "element" && next.tagName === "tr";
}
/**
* Whether to omit `</td>` or `</th>`.
*
* @param {Element} _
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the closing tag can be omitted.
*/
function cells(_$2, index, parent) {
	const next = siblingAfter(parent, index);
	return !next || next.type === "element" && (next.tagName === "td" || next.tagName === "th");
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/omission/opening.js
const opening = omission({
	body,
	colgroup,
	head,
	html: html$1,
	tbody
});
/**
* Whether to omit `<html>`.
*
* @param {Element} node
*   Element.
* @returns {boolean}
*   Whether the opening tag can be omitted.
*/
function html$1(node) {
	const head$1 = siblingAfter(node, -1);
	return !head$1 || head$1.type !== "comment";
}
/**
* Whether to omit `<head>`.
*
* @param {Element} node
*   Element.
* @returns {boolean}
*   Whether the opening tag can be omitted.
*/
function head(node) {
	/** @type {Set<string>} */
	const seen = new Set();
	for (const child$1 of node.children) {
		if (child$1.type === "element" && (child$1.tagName === "base" || child$1.tagName === "title")) {
			if (seen.has(child$1.tagName)) return false;
			seen.add(child$1.tagName);
		}
	}
	const child = node.children[0];
	return !child || child.type === "element";
}
/**
* Whether to omit `<body>`.
*
* @param {Element} node
*   Element.
* @returns {boolean}
*   Whether the opening tag can be omitted.
*/
function body(node) {
	const head$1 = siblingAfter(node, -1, true);
	return !head$1 || head$1.type !== "comment" && !(head$1.type === "text" && whitespace(head$1.value.charAt(0))) && !(head$1.type === "element" && (head$1.tagName === "meta" || head$1.tagName === "link" || head$1.tagName === "script" || head$1.tagName === "style" || head$1.tagName === "template"));
}
/**
* Whether to omit `<colgroup>`.
* The spec describes some logic for the opening tag, but it’s easier to
* implement in the closing tag, to the same effect, so we handle it there
* instead.
*
* @param {Element} node
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the opening tag can be omitted.
*/
function colgroup(node, index, parent) {
	const previous = siblingBefore(parent, index);
	const head$1 = siblingAfter(node, -1, true);
	if (parent && previous && previous.type === "element" && previous.tagName === "colgroup" && closing(previous, parent.children.indexOf(previous), parent)) {
		return false;
	}
	return Boolean(head$1 && head$1.type === "element" && head$1.tagName === "col");
}
/**
* Whether to omit `<tbody>`.
*
* @param {Element} node
*   Element.
* @param {number | undefined} index
*   Index of element in parent.
* @param {Parents | undefined} parent
*   Parent of element.
* @returns {boolean}
*   Whether the opening tag can be omitted.
*/
function tbody(node, index, parent) {
	const previous = siblingBefore(parent, index);
	const head$1 = siblingAfter(node, -1);
	if (parent && previous && previous.type === "element" && (previous.tagName === "thead" || previous.tagName === "tbody") && closing(previous, parent.children.indexOf(previous), parent)) {
		return false;
	}
	return Boolean(head$1 && head$1.type === "element" && head$1.tagName === "tr");
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/handle/element.js
/**
* Maps of subsets.
*
* Each value is a matrix of tuples.
* The value at `0` causes parse errors, the value at `1` is valid.
* Of both, the value at `0` is unsafe, and the value at `1` is safe.
*
* @type {Record<'double' | 'name' | 'single' | 'unquoted', Array<[Array<string>, Array<string>]>>}
*/
const constants = {
	name: [["	\n\f\r &/=>".split(""), "	\n\f\r \"&'/=>`".split("")], ["\0	\n\f\r \"&'/<=>".split(""), "\0	\n\f\r \"&'/<=>`".split("")]],
	unquoted: [["	\n\f\r &>".split(""), "\0	\n\f\r \"&'<=>`".split("")], ["\0	\n\f\r \"&'<=>`".split(""), "\0	\n\f\r \"&'<=>`".split("")]],
	single: [["&'".split(""), "\"&'`".split("")], ["\0&'".split(""), "\0\"&'`".split("")]],
	double: [["\"&".split(""), "\"&'`".split("")], ["\0\"&".split(""), "\0\"&'`".split("")]]
};
/**
* Serialize an element node.
*
* @param {Element} node
*   Node to handle.
* @param {number | undefined} index
*   Index of `node` in `parent.
* @param {Parents | undefined} parent
*   Parent of `node`.
* @param {State} state
*   Info passed around about the current state.
* @returns {string}
*   Serialized node.
*/
function element(node, index, parent, state) {
	const schema = state.schema;
	const omit = schema.space === "svg" ? false : state.settings.omitOptionalTags;
	let selfClosing = schema.space === "svg" ? state.settings.closeEmptyElements : state.settings.voids.includes(node.tagName.toLowerCase());
	/** @type {Array<string>} */
	const parts = [];
	/** @type {string} */
	let last;
	if (schema.space === "html" && node.tagName === "svg") {
		state.schema = svg;
	}
	const attributes = serializeAttributes(state, node.properties);
	const content = state.all(schema.space === "html" && node.tagName === "template" ? node.content : node);
	state.schema = schema;
	if (content) selfClosing = false;
	if (attributes || !omit || !opening(node, index, parent)) {
		parts.push("<", node.tagName, attributes ? " " + attributes : "");
		if (selfClosing && (schema.space === "svg" || state.settings.closeSelfClosing)) {
			last = attributes.charAt(attributes.length - 1);
			if (!state.settings.tightSelfClosing || last === "/" || last && last !== "\"" && last !== "'") {
				parts.push(" ");
			}
			parts.push("/");
		}
		parts.push(">");
	}
	parts.push(content);
	if (!selfClosing && (!omit || !closing(node, index, parent))) {
		parts.push("</" + node.tagName + ">");
	}
	return parts.join("");
}
/**
* @param {State} state
* @param {Properties | null | undefined} properties
* @returns {string}
*/
function serializeAttributes(state, properties) {
	/** @type {Array<string>} */
	const values = [];
	let index = -1;
	/** @type {string} */
	let key$1;
	if (properties) {
		for (key$1 in properties) {
			if (properties[key$1] !== null && properties[key$1] !== undefined) {
				const value = serializeAttribute(state, key$1, properties[key$1]);
				if (value) values.push(value);
			}
		}
	}
	while (++index < values.length) {
		const last = state.settings.tightAttributes ? values[index].charAt(values[index].length - 1) : undefined;
		if (index !== values.length - 1 && last !== "\"" && last !== "'") {
			values[index] += " ";
		}
	}
	return values.join("");
}
/**
* @param {State} state
* @param {string} key
* @param {Properties[keyof Properties]} value
* @returns {string}
*/
function serializeAttribute(state, key$1, value) {
	const info = find(state.schema, key$1);
	const x$1 = state.settings.allowParseErrors && state.schema.space === "html" ? 0 : 1;
	const y$2 = state.settings.allowDangerousCharacters ? 0 : 1;
	let quote = state.quote;
	/** @type {string | undefined} */
	let result;
	if (info.overloadedBoolean && (value === info.attribute || value === "")) {
		value = true;
	} else if ((info.boolean || info.overloadedBoolean) && (typeof value !== "string" || value === info.attribute || value === "")) {
		value = Boolean(value);
	}
	if (value === null || value === undefined || value === false || typeof value === "number" && Number.isNaN(value)) {
		return "";
	}
	const name = stringifyEntities(info.attribute, Object.assign({}, state.settings.characterReferences, { subset: constants.name[x$1][y$2] }));
	if (value === true) return name;
	value = Array.isArray(value) ? (info.commaSeparated ? stringify$1 : stringify$2)(value, { padLeft: !state.settings.tightCommaSeparatedLists }) : String(value);
	if (state.settings.collapseEmptyAttributes && !value) return name;
	if (state.settings.preferUnquoted) {
		result = stringifyEntities(value, Object.assign({}, state.settings.characterReferences, {
			attribute: true,
			subset: constants.unquoted[x$1][y$2]
		}));
	}
	if (result !== value) {
		if (state.settings.quoteSmart && ccount(value, quote) > ccount(value, state.alternative)) {
			quote = state.alternative;
		}
		result = quote + stringifyEntities(value, Object.assign({}, state.settings.characterReferences, {
			subset: (quote === "'" ? constants.single : constants.double)[x$1][y$2],
			attribute: true
		})) + quote;
	}
	return name + (result ? "=" + result : result);
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/handle/text.js
const textEntitySubset = ["<", "&"];
/**
* Serialize a text node.
*
* @param {Raw | Text} node
*   Node to handle.
* @param {number | undefined} _
*   Index of `node` in `parent.
* @param {Parents | undefined} parent
*   Parent of `node`.
* @param {State} state
*   Info passed around about the current state.
* @returns {string}
*   Serialized node.
*/
function text(node, _$2, parent, state) {
	return parent && parent.type === "element" && (parent.tagName === "script" || parent.tagName === "style") ? node.value : stringifyEntities(node.value, Object.assign({}, state.settings.characterReferences, { subset: textEntitySubset }));
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/handle/raw.js
/**
* Serialize a raw node.
*
* @param {Raw} node
*   Node to handle.
* @param {number | undefined} index
*   Index of `node` in `parent.
* @param {Parents | undefined} parent
*   Parent of `node`.
* @param {State} state
*   Info passed around about the current state.
* @returns {string}
*   Serialized node.
*/
function raw(node, index, parent, state) {
	return state.settings.allowDangerousHtml ? node.value : text(node, index, parent, state);
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/handle/root.js
/**
* @import {Parents, Root} from 'hast'
* @import {State} from '../index.js'
*/
/**
* Serialize a root.
*
* @param {Root} node
*   Node to handle.
* @param {number | undefined} _1
*   Index of `node` in `parent.
* @param {Parents | undefined} _2
*   Parent of `node`.
* @param {State} state
*   Info passed around about the current state.
* @returns {string}
*   Serialized node.
*/
function root(node, _1, _2, state) {
	return state.all(node);
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/handle/index.js
/**
* @type {(node: Nodes, index: number | undefined, parent: Parents | undefined, state: State) => string}
*/
const handle = zwitch("type", {
	invalid,
	unknown,
	handlers: {
		comment,
		doctype,
		element,
		raw,
		root,
		text
	}
});
/**
* Fail when a non-node is found in the tree.
*
* @param {unknown} node
*   Unknown value.
* @returns {never}
*   Never.
*/
function invalid(node) {
	throw new Error("Expected node, not `" + node + "`");
}
/**
* Fail when a node with an unknown type is found in the tree.
*
* @param {unknown} node_
*  Unknown node.
* @returns {never}
*   Never.
*/
function unknown(node_) {
	const node = node_;
	throw new Error("Cannot compile unknown node `" + node.type + "`");
}

//#endregion
//#region ../../node_modules/.bun/hast-util-to-html@9.0.5/node_modules/hast-util-to-html/lib/index.js
/** @type {Options} */
const emptyOptions = {};
/** @type {CharacterReferences} */
const emptyCharacterReferences = {};
/** @type {Array<never>} */
const emptyChildren = [];
/**
* Serialize hast as HTML.
*
* @param {Array<RootContent> | Nodes} tree
*   Tree to serialize.
* @param {Options | null | undefined} [options]
*   Configuration (optional).
* @returns {string}
*   Serialized HTML.
*/
function toHtml(tree, options) {
	const options_ = options || emptyOptions;
	const quote = options_.quote || "\"";
	const alternative = quote === "\"" ? "'" : "\"";
	if (quote !== "\"" && quote !== "'") {
		throw new Error("Invalid quote `" + quote + "`, expected `'` or `\"`");
	}
	/** @type {State} */
	const state = {
		one,
		all,
		settings: {
			omitOptionalTags: options_.omitOptionalTags || false,
			allowParseErrors: options_.allowParseErrors || false,
			allowDangerousCharacters: options_.allowDangerousCharacters || false,
			quoteSmart: options_.quoteSmart || false,
			preferUnquoted: options_.preferUnquoted || false,
			tightAttributes: options_.tightAttributes || false,
			upperDoctype: options_.upperDoctype || false,
			tightDoctype: options_.tightDoctype || false,
			bogusComments: options_.bogusComments || false,
			tightCommaSeparatedLists: options_.tightCommaSeparatedLists || false,
			tightSelfClosing: options_.tightSelfClosing || false,
			collapseEmptyAttributes: options_.collapseEmptyAttributes || false,
			allowDangerousHtml: options_.allowDangerousHtml || false,
			voids: options_.voids || htmlVoidElements,
			characterReferences: options_.characterReferences || emptyCharacterReferences,
			closeSelfClosing: options_.closeSelfClosing || false,
			closeEmptyElements: options_.closeEmptyElements || false
		},
		schema: options_.space === "svg" ? svg : html,
		quote,
		alternative
	};
	return state.one(Array.isArray(tree) ? {
		type: "root",
		children: tree
	} : tree, undefined, undefined);
}
/**
* Serialize a node.
*
* @this {State}
*   Info passed around about the current state.
* @param {Nodes} node
*   Node to handle.
* @param {number | undefined} index
*   Index of `node` in `parent.
* @param {Parents | undefined} parent
*   Parent of `node`.
* @returns {string}
*   Serialized node.
*/
function one(node, index, parent) {
	return handle(node, index, parent, this);
}
/**
* Serialize all children of `parent`.
*
* @this {State}
*   Info passed around about the current state.
* @param {Parents | undefined} parent
*   Parent whose children to serialize.
* @returns {string}
*/
function all(parent) {
	/** @type {Array<string>} */
	const results = [];
	const children = parent && parent.children || emptyChildren;
	let index = -1;
	while (++index < children.length) {
		results[index] = this.one(children[index], index, parent);
	}
	return results.join("");
}

//#endregion
//#region ../../node_modules/.bun/@shikijs+core@4.0.2/node_modules/@shikijs/core/dist/index.mjs
/**
* Utility to append class to a hast node
*
* If the `property.class` is a string, it will be splitted by space and converted to an array.
*/
function addClassToHast(node, className) {
	if (!className) return node;
	node.properties ||= {};
	node.properties.class ||= [];
	if (typeof node.properties.class === "string") node.properties.class = node.properties.class.split(/\s+/g);
	if (!Array.isArray(node.properties.class)) node.properties.class = [];
	const targets = Array.isArray(className) ? className : className.split(/\s+/g);
	for (const c of targets) if (c && !node.properties.class.includes(c)) node.properties.class.push(c);
	return node;
}
/**
* Creates a converter between index and position in a code block.
*
* Overflow/underflow are unchecked.
*/
function createPositionConverter(code) {
	const lines = splitLines$1(code, true).map(([line]) => line);
	function indexToPos(index) {
		if (index === code.length) return {
			line: lines.length - 1,
			character: lines[lines.length - 1].length
		};
		let character = index;
		let line = 0;
		for (const lineText of lines) {
			if (character < lineText.length) break;
			character -= lineText.length;
			line++;
		}
		return {
			line,
			character
		};
	}
	function posToIndex(line, character) {
		let index = 0;
		for (let i$2 = 0; i$2 < line; i$2++) index += lines[i$2].length;
		index += character;
		return index;
	}
	return {
		lines,
		indexToPos,
		posToIndex
	};
}
/**
* Guess embedded languages from given code and highlighter.
*
* When highlighter is provided, only bundled languages will be included.
*
* @param code - The code string to analyze
* @param _lang - The primary language of the code (currently unused)
* @param highlighter - Optional highlighter instance to validate languages
* @returns Array of detected language identifiers
*
* @example
* ```ts
* // Detects 'javascript' from Vue SFC
* guessEmbeddedLanguages('<script lang="javascript">')
*
* // Detects 'python' from markdown code block
* guessEmbeddedLanguages('```python\nprint("hi")\n```')
* ```
*/
function guessEmbeddedLanguages(code, _lang, highlighter$1) {
	const langs = /* @__PURE__ */ new Set();
	for (const match of code.matchAll(/:?lang=["']([^"']+)["']/g)) {
		const lang = match[1].toLowerCase().trim();
		if (lang) langs.add(lang);
	}
	for (const match of code.matchAll(/(?:```|~~~)([\w-]+)/g)) {
		const lang = match[1].toLowerCase().trim();
		if (lang) langs.add(lang);
	}
	for (const match of code.matchAll(/\\begin\{([\w-]+)\}/g)) {
		const lang = match[1].toLowerCase().trim();
		if (lang) langs.add(lang);
	}
	for (const match of code.matchAll(/<script\s+(?:type|lang)=["']([^"']+)["']/gi)) {
		const fullType = match[1].toLowerCase().trim();
		const lang = fullType.includes("/") ? fullType.split("/").pop() : fullType;
		if (lang) langs.add(lang);
	}
	if (!highlighter$1) return Array.from(langs);
	const bundle = highlighter$1.getBundledLanguages();
	return Array.from(langs).filter((l$2) => l$2 && bundle[l$2]);
}
const DEFAULT_COLOR_LIGHT_DARK = "light-dark()";
const COLOR_KEYS = ["color", "background-color"];
/**
* Split a token into multiple tokens by given offsets.
*
* The offsets are relative to the token, and should be sorted.
*/
function splitToken(token$1, offsets) {
	let lastOffset = 0;
	const tokens = [];
	for (const offset of offsets) {
		if (offset > lastOffset) tokens.push({
			...token$1,
			content: token$1.content.slice(lastOffset, offset),
			offset: token$1.offset + lastOffset
		});
		lastOffset = offset;
	}
	if (lastOffset < token$1.content.length) tokens.push({
		...token$1,
		content: token$1.content.slice(lastOffset),
		offset: token$1.offset + lastOffset
	});
	return tokens;
}
/**
* Split 2D tokens array by given breakpoints.
*/
function splitTokens(tokens, breakpoints) {
	const sorted = Array.from(breakpoints instanceof Set ? breakpoints : new Set(breakpoints)).sort((a$1, b$2) => a$1 - b$2);
	if (!sorted.length) return tokens;
	return tokens.map((line) => {
		return line.flatMap((token$1) => {
			const breakpointsInToken = sorted.filter((i$2) => token$1.offset < i$2 && i$2 < token$1.offset + token$1.content.length).map((i$2) => i$2 - token$1.offset).sort((a$1, b$2) => a$1 - b$2);
			if (!breakpointsInToken.length) return token$1;
			return splitToken(token$1, breakpointsInToken);
		});
	});
}
function flatTokenVariants(merged, variantsOrder, cssVariablePrefix, defaultColor, colorsRendering = "css-vars") {
	const token$1 = {
		content: merged.content,
		explanation: merged.explanation,
		offset: merged.offset
	};
	const styles = variantsOrder.map((t) => getTokenStyleObject(merged.variants[t]));
	const styleKeys = new Set(styles.flatMap((t) => Object.keys(t)));
	const mergedStyles = {};
	const varKey = (idx, key$1) => {
		const keyName = key$1 === "color" ? "" : key$1 === "background-color" ? "-bg" : `-${key$1}`;
		return cssVariablePrefix + variantsOrder[idx] + (key$1 === "color" ? "" : keyName);
	};
	styles.forEach((cur, idx) => {
		for (const key$1 of styleKeys) {
			const value = cur[key$1] || "inherit";
			if (idx === 0 && defaultColor && COLOR_KEYS.includes(key$1)) if (defaultColor === DEFAULT_COLOR_LIGHT_DARK && styles.length > 1) {
				const lightIndex = variantsOrder.findIndex((t) => t === "light");
				const darkIndex = variantsOrder.findIndex((t) => t === "dark");
				if (lightIndex === -1 || darkIndex === -1) throw new ShikiError$1("When using `defaultColor: \"light-dark()\"`, you must provide both `light` and `dark` themes");
				mergedStyles[key$1] = `light-dark(${styles[lightIndex][key$1] || "inherit"}, ${styles[darkIndex][key$1] || "inherit"})`;
				if (colorsRendering === "css-vars") mergedStyles[varKey(idx, key$1)] = value;
			} else mergedStyles[key$1] = value;
			else if (colorsRendering === "css-vars") mergedStyles[varKey(idx, key$1)] = value;
		}
	});
	token$1.htmlStyle = mergedStyles;
	return token$1;
}
function getTokenStyleObject(token$1) {
	const styles = {};
	if (token$1.color) styles.color = token$1.color;
	if (token$1.bgColor) styles["background-color"] = token$1.bgColor;
	if (token$1.fontStyle) {
		if (token$1.fontStyle & FontStyle.Italic) styles["font-style"] = "italic";
		if (token$1.fontStyle & FontStyle.Bold) styles["font-weight"] = "bold";
		const decorations$1 = [];
		if (token$1.fontStyle & FontStyle.Underline) decorations$1.push("underline");
		if (token$1.fontStyle & FontStyle.Strikethrough) decorations$1.push("line-through");
		if (decorations$1.length) styles["text-decoration"] = decorations$1.join(" ");
	}
	return styles;
}
function stringifyTokenStyle(token$1) {
	if (typeof token$1 === "string") return token$1;
	return Object.entries(token$1).map(([key$1, value]) => `${key$1}:${value}`).join(";");
}
/**
* A built-in transformer to add decorations to the highlighted code.
*/
function transformerDecorations() {
	const map = /* @__PURE__ */ new WeakMap();
	function getContext(shiki) {
		if (!map.has(shiki.meta)) {
			const converter = createPositionConverter(shiki.source);
			function normalizePosition(p$1) {
				if (typeof p$1 === "number") {
					if (p$1 < 0 || p$1 > shiki.source.length) throw new ShikiError$1(`Invalid decoration offset: ${p$1}. Code length: ${shiki.source.length}`);
					return {
						...converter.indexToPos(p$1),
						offset: p$1
					};
				} else {
					const line = converter.lines[p$1.line];
					if (line === void 0) throw new ShikiError$1(`Invalid decoration position ${JSON.stringify(p$1)}. Lines length: ${converter.lines.length}`);
					let character = p$1.character;
					if (character < 0) character = line.length + character;
					if (character < 0 || character > line.length) throw new ShikiError$1(`Invalid decoration position ${JSON.stringify(p$1)}. Line ${p$1.line} length: ${line.length}`);
					return {
						...p$1,
						character,
						offset: converter.posToIndex(p$1.line, character)
					};
				}
			}
			const decorations$1 = (shiki.options.decorations || []).map((d$1) => ({
				...d$1,
				start: normalizePosition(d$1.start),
				end: normalizePosition(d$1.end)
			}));
			verifyIntersections(decorations$1);
			map.set(shiki.meta, {
				decorations: decorations$1,
				converter,
				source: shiki.source
			});
		}
		return map.get(shiki.meta);
	}
	return {
		name: "shiki:decorations",
		tokens(tokens) {
			if (!this.options.decorations?.length) return;
			return splitTokens(tokens, getContext(this).decorations.flatMap((d$1) => [d$1.start.offset, d$1.end.offset]));
		},
		code(codeEl) {
			if (!this.options.decorations?.length) return;
			const ctx = getContext(this);
			const lines = Array.from(codeEl.children).filter((i$2) => i$2.type === "element" && i$2.tagName === "span");
			if (lines.length !== ctx.converter.lines.length) throw new ShikiError$1(`Number of lines in code element (${lines.length}) does not match the number of lines in the source (${ctx.converter.lines.length}). Failed to apply decorations.`);
			function applyLineSection(line, start, end, decoration) {
				const lineEl = lines[line];
				let text$1 = "";
				let startIndex = -1;
				let endIndex = -1;
				if (start === 0) startIndex = 0;
				if (end === 0) endIndex = 0;
				if (end === Number.POSITIVE_INFINITY) endIndex = lineEl.children.length;
				if (startIndex === -1 || endIndex === -1) for (let i$2 = 0; i$2 < lineEl.children.length; i$2++) {
					text$1 += stringify(lineEl.children[i$2]);
					if (startIndex === -1 && text$1.length === start) startIndex = i$2 + 1;
					if (endIndex === -1 && text$1.length === end) endIndex = i$2 + 1;
				}
				if (startIndex === -1) throw new ShikiError$1(`Failed to find start index for decoration ${JSON.stringify(decoration.start)}`);
				if (endIndex === -1) throw new ShikiError$1(`Failed to find end index for decoration ${JSON.stringify(decoration.end)}`);
				const children = lineEl.children.slice(startIndex, endIndex);
				if (!decoration.alwaysWrap && children.length === lineEl.children.length) applyDecoration(lineEl, decoration, "line");
				else if (!decoration.alwaysWrap && children.length === 1 && children[0].type === "element") applyDecoration(children[0], decoration, "token");
				else {
					const wrapper = {
						type: "element",
						tagName: "span",
						properties: {},
						children
					};
					applyDecoration(wrapper, decoration, "wrapper");
					lineEl.children.splice(startIndex, children.length, wrapper);
				}
			}
			function applyLine(line, decoration) {
				lines[line] = applyDecoration(lines[line], decoration, "line");
			}
			function applyDecoration(el, decoration, type) {
				const properties = decoration.properties || {};
				const transform$1 = decoration.transform || ((i$2) => i$2);
				el.tagName = decoration.tagName || "span";
				el.properties = {
					...el.properties,
					...properties,
					class: el.properties.class
				};
				if (decoration.properties?.class) addClassToHast(el, decoration.properties.class);
				el = transform$1(el, type) || el;
				return el;
			}
			const lineApplies = [];
			const sorted = ctx.decorations.sort((a$1, b$2) => b$2.start.offset - a$1.start.offset || a$1.end.offset - b$2.end.offset);
			for (const decoration of sorted) {
				const { start, end } = decoration;
				if (start.line === end.line) applyLineSection(start.line, start.character, end.character, decoration);
				else if (start.line < end.line) {
					applyLineSection(start.line, start.character, Number.POSITIVE_INFINITY, decoration);
					for (let i$2 = start.line + 1; i$2 < end.line; i$2++) lineApplies.unshift(() => applyLine(i$2, decoration));
					applyLineSection(end.line, 0, end.character, decoration);
				}
			}
			lineApplies.forEach((i$2) => i$2());
		}
	};
}
function verifyIntersections(items) {
	for (let i$2 = 0; i$2 < items.length; i$2++) {
		const foo = items[i$2];
		if (foo.start.offset > foo.end.offset) throw new ShikiError$1(`Invalid decoration range: ${JSON.stringify(foo.start)} - ${JSON.stringify(foo.end)}`);
		for (let j$1 = i$2 + 1; j$1 < items.length; j$1++) {
			const bar = items[j$1];
			const isFooHasBarStart = foo.start.offset <= bar.start.offset && bar.start.offset < foo.end.offset;
			const isFooHasBarEnd = foo.start.offset < bar.end.offset && bar.end.offset <= foo.end.offset;
			const isBarHasFooStart = bar.start.offset <= foo.start.offset && foo.start.offset < bar.end.offset;
			const isBarHasFooEnd = bar.start.offset < foo.end.offset && foo.end.offset <= bar.end.offset;
			if (isFooHasBarStart || isFooHasBarEnd || isBarHasFooStart || isBarHasFooEnd) {
				if (isFooHasBarStart && isFooHasBarEnd) continue;
				if (isBarHasFooStart && isBarHasFooEnd) continue;
				if (isBarHasFooStart && foo.start.offset === foo.end.offset) continue;
				if (isFooHasBarEnd && bar.start.offset === bar.end.offset) continue;
				throw new ShikiError$1(`Decorations ${JSON.stringify(foo.start)} and ${JSON.stringify(bar.start)} intersect.`);
			}
		}
	}
}
function stringify(el) {
	if (el.type === "text") return el.value;
	if (el.type === "element") return el.children.map(stringify).join("");
	return "";
}
const builtInTransformers = [/* @__PURE__ */ transformerDecorations()];
function getTransformers(options) {
	const transformers = sortTransformersByEnforcement(options.transformers || []);
	return [
		...transformers.pre,
		...transformers.normal,
		...transformers.post,
		...builtInTransformers
	];
}
function sortTransformersByEnforcement(transformers) {
	const pre = [];
	const post = [];
	const normal = [];
	for (const transformer of transformers) switch (transformer.enforce) {
		case "pre":
			pre.push(transformer);
			break;
		case "post":
			post.push(transformer);
			break;
		default: normal.push(transformer);
	}
	return {
		pre,
		post,
		normal
	};
}
var namedColors = [
	"black",
	"red",
	"green",
	"yellow",
	"blue",
	"magenta",
	"cyan",
	"white",
	"brightBlack",
	"brightRed",
	"brightGreen",
	"brightYellow",
	"brightBlue",
	"brightMagenta",
	"brightCyan",
	"brightWhite"
];
var decorations = {
	1: "bold",
	2: "dim",
	3: "italic",
	4: "underline",
	7: "reverse",
	8: "hidden",
	9: "strikethrough"
};
function findSequence(value, position) {
	const nextEscape = value.indexOf("\x1B", position);
	if (nextEscape !== -1) {
		if (value[nextEscape + 1] === "[") {
			const nextClose = value.indexOf("m", nextEscape);
			if (nextClose !== -1) return {
				sequence: value.substring(nextEscape + 2, nextClose).split(";"),
				startPosition: nextEscape,
				position: nextClose + 1
			};
		}
	}
	return { position: value.length };
}
function parseColor(sequence) {
	const colorMode = sequence.shift();
	if (colorMode === "2") {
		const rgb = sequence.splice(0, 3).map((x$1) => Number.parseInt(x$1));
		if (rgb.length !== 3 || rgb.some((x$1) => Number.isNaN(x$1))) return;
		return {
			type: "rgb",
			rgb
		};
	} else if (colorMode === "5") {
		const index = sequence.shift();
		if (index) return {
			type: "table",
			index: Number(index)
		};
	}
}
function parseSequence(sequence) {
	const commands = [];
	while (sequence.length > 0) {
		const code = sequence.shift();
		if (!code) continue;
		const codeInt = Number.parseInt(code);
		if (Number.isNaN(codeInt)) continue;
		if (codeInt === 0) commands.push({ type: "resetAll" });
		else if (codeInt <= 9) {
			if (decorations[codeInt]) commands.push({
				type: "setDecoration",
				value: decorations[codeInt]
			});
		} else if (codeInt <= 29) {
			const decoration = decorations[codeInt - 20];
			if (decoration) {
				commands.push({
					type: "resetDecoration",
					value: decoration
				});
				if (decoration === "dim") commands.push({
					type: "resetDecoration",
					value: "bold"
				});
			}
		} else if (codeInt <= 37) commands.push({
			type: "setForegroundColor",
			value: {
				type: "named",
				name: namedColors[codeInt - 30]
			}
		});
		else if (codeInt === 38) {
			const color = parseColor(sequence);
			if (color) commands.push({
				type: "setForegroundColor",
				value: color
			});
		} else if (codeInt === 39) commands.push({ type: "resetForegroundColor" });
		else if (codeInt <= 47) commands.push({
			type: "setBackgroundColor",
			value: {
				type: "named",
				name: namedColors[codeInt - 40]
			}
		});
		else if (codeInt === 48) {
			const color = parseColor(sequence);
			if (color) commands.push({
				type: "setBackgroundColor",
				value: color
			});
		} else if (codeInt === 49) commands.push({ type: "resetBackgroundColor" });
		else if (codeInt === 53) commands.push({
			type: "setDecoration",
			value: "overline"
		});
		else if (codeInt === 55) commands.push({
			type: "resetDecoration",
			value: "overline"
		});
		else if (codeInt >= 90 && codeInt <= 97) commands.push({
			type: "setForegroundColor",
			value: {
				type: "named",
				name: namedColors[codeInt - 90 + 8]
			}
		});
		else if (codeInt >= 100 && codeInt <= 107) commands.push({
			type: "setBackgroundColor",
			value: {
				type: "named",
				name: namedColors[codeInt - 100 + 8]
			}
		});
	}
	return commands;
}
function createAnsiSequenceParser() {
	let foreground = null;
	let background = null;
	let decorations2 = /* @__PURE__ */ new Set();
	return { parse(value) {
		const tokens = [];
		let position = 0;
		do {
			const findResult = findSequence(value, position);
			const text$1 = findResult.sequence ? value.substring(position, findResult.startPosition) : value.substring(position);
			if (text$1.length > 0) tokens.push({
				value: text$1,
				foreground,
				background,
				decorations: new Set(decorations2)
			});
			if (findResult.sequence) {
				const commands = parseSequence(findResult.sequence);
				for (const styleToken of commands) if (styleToken.type === "resetAll") {
					foreground = null;
					background = null;
					decorations2.clear();
				} else if (styleToken.type === "resetForegroundColor") foreground = null;
				else if (styleToken.type === "resetBackgroundColor") background = null;
				else if (styleToken.type === "resetDecoration") decorations2.delete(styleToken.value);
				for (const styleToken of commands) if (styleToken.type === "setForegroundColor") foreground = styleToken.value;
				else if (styleToken.type === "setBackgroundColor") background = styleToken.value;
				else if (styleToken.type === "setDecoration") decorations2.add(styleToken.value);
			}
			position = findResult.position;
		} while (position < value.length);
		return tokens;
	} };
}
var defaultNamedColorsMap = {
	black: "#000000",
	red: "#bb0000",
	green: "#00bb00",
	yellow: "#bbbb00",
	blue: "#0000bb",
	magenta: "#ff00ff",
	cyan: "#00bbbb",
	white: "#eeeeee",
	brightBlack: "#555555",
	brightRed: "#ff5555",
	brightGreen: "#00ff00",
	brightYellow: "#ffff55",
	brightBlue: "#5555ff",
	brightMagenta: "#ff55ff",
	brightCyan: "#55ffff",
	brightWhite: "#ffffff"
};
function createColorPalette(namedColorsMap = defaultNamedColorsMap) {
	function namedColor(name) {
		return namedColorsMap[name];
	}
	function rgbColor(rgb) {
		return `#${rgb.map((x$1) => Math.max(0, Math.min(x$1, 255)).toString(16).padStart(2, "0")).join("")}`;
	}
	let colorTable;
	function getColorTable() {
		if (colorTable) return colorTable;
		colorTable = [];
		for (let i$2 = 0; i$2 < namedColors.length; i$2++) colorTable.push(namedColor(namedColors[i$2]));
		let levels = [
			0,
			95,
			135,
			175,
			215,
			255
		];
		for (let r$3 = 0; r$3 < 6; r$3++) for (let g = 0; g < 6; g++) for (let b$2 = 0; b$2 < 6; b$2++) colorTable.push(rgbColor([
			levels[r$3],
			levels[g],
			levels[b$2]
		]));
		let level = 8;
		for (let i$2 = 0; i$2 < 24; i$2++, level += 10) colorTable.push(rgbColor([
			level,
			level,
			level
		]));
		return colorTable;
	}
	function tableColor(index) {
		return getColorTable()[index];
	}
	function value(color) {
		switch (color.type) {
			case "named": return namedColor(color.name);
			case "rgb": return rgbColor(color.rgb);
			case "table": return tableColor(color.index);
		}
	}
	return { value };
}
/**
* Default ANSI palette (VSCode compatible fallbacks)
* Used when the theme does not define terminal.ansi* colors.
*/
const defaultAnsiColors = {
	black: "#000000",
	red: "#cd3131",
	green: "#0DBC79",
	yellow: "#E5E510",
	blue: "#2472C8",
	magenta: "#BC3FBC",
	cyan: "#11A8CD",
	white: "#E5E5E5",
	brightBlack: "#666666",
	brightRed: "#F14C4C",
	brightGreen: "#23D18B",
	brightYellow: "#F5F543",
	brightBlue: "#3B8EEA",
	brightMagenta: "#D670D6",
	brightCyan: "#29B8DB",
	brightWhite: "#FFFFFF"
};
function tokenizeAnsiWithTheme(theme, fileContents, options) {
	const colorReplacements = resolveColorReplacements(theme, options);
	const lines = splitLines$1(fileContents);
	const colorPalette = createColorPalette(Object.fromEntries(namedColors.map((name) => {
		const key$1 = `terminal.ansi${name[0].toUpperCase()}${name.substring(1)}`;
		return [name, theme.colors?.[key$1] || defaultAnsiColors[name]];
	})));
	const parser = createAnsiSequenceParser();
	return lines.map((line) => parser.parse(line[0]).map((token$1) => {
		let color;
		let bgColor;
		if (token$1.decorations.has("reverse")) {
			color = token$1.background ? colorPalette.value(token$1.background) : theme.bg;
			bgColor = token$1.foreground ? colorPalette.value(token$1.foreground) : theme.fg;
		} else {
			color = token$1.foreground ? colorPalette.value(token$1.foreground) : theme.fg;
			bgColor = token$1.background ? colorPalette.value(token$1.background) : void 0;
		}
		color = applyColorReplacements(color, colorReplacements);
		bgColor = applyColorReplacements(bgColor, colorReplacements);
		if (token$1.decorations.has("dim")) color = dimColor(color);
		let fontStyle = FontStyle.None;
		if (token$1.decorations.has("bold")) fontStyle |= FontStyle.Bold;
		if (token$1.decorations.has("italic")) fontStyle |= FontStyle.Italic;
		if (token$1.decorations.has("underline")) fontStyle |= FontStyle.Underline;
		if (token$1.decorations.has("strikethrough")) fontStyle |= FontStyle.Strikethrough;
		return {
			content: token$1.value,
			offset: line[1],
			color,
			bgColor,
			fontStyle
		};
	}));
}
/**
* Adds 50% alpha to a hex color string or the "-dim" postfix to a CSS variable
*/
function dimColor(color) {
	const hexMatch = color.match(/#([0-9a-f]{3,8})/i);
	if (hexMatch) {
		const hex = hexMatch[1];
		if (hex.length === 8) {
			const alpha = Math.round(Number.parseInt(hex.slice(6, 8), 16) / 2).toString(16).padStart(2, "0");
			return `#${hex.slice(0, 6)}${alpha}`;
		} else if (hex.length === 6) return `#${hex}80`;
		else if (hex.length === 4) {
			const r$3 = hex[0];
			const g = hex[1];
			const b$2 = hex[2];
			const a$1 = hex[3];
			return `#${r$3}${r$3}${g}${g}${b$2}${b$2}${Math.round(Number.parseInt(`${a$1}${a$1}`, 16) / 2).toString(16).padStart(2, "0")}`;
		} else if (hex.length === 3) {
			const r$3 = hex[0];
			const g = hex[1];
			const b$2 = hex[2];
			return `#${r$3}${r$3}${g}${g}${b$2}${b$2}80`;
		}
	}
	const cssVarMatch = color.match(/var\((--[\w-]+-ansi-[\w-]+)\)/);
	if (cssVarMatch) return `var(${cssVarMatch[1]}-dim)`;
	return color;
}
/**
* Code to tokens, with a simple theme.
* This wraps the tokenizer's implementation to add ANSI support.
*/
function codeToTokensBase$1(primitive, code, options = {}) {
	const lang = primitive.resolveLangAlias(options.lang || "text");
	const { theme: themeName = primitive.getLoadedThemes()[0] } = options;
	if (!isPlainLang(lang) && !isNoneTheme(themeName) && lang === "ansi") {
		const { theme } = primitive.setTheme(themeName);
		return tokenizeAnsiWithTheme(theme, code, options);
	}
	return codeToTokensBase(primitive, code, options);
}
/**
* High-level code-to-tokens API.
*
* It will use `codeToTokensWithThemes` or `codeToTokensBase` based on the options.
*/
function codeToTokens(primitive, code, options) {
	let bg;
	let fg;
	let tokens;
	let themeName;
	let rootStyle;
	let grammarState;
	if ("themes" in options) {
		const { defaultColor = "light", cssVariablePrefix = "--shiki-", colorsRendering = "css-vars" } = options;
		const themes = Object.entries(options.themes).filter((i$2) => i$2[1]).map((i$2) => ({
			color: i$2[0],
			theme: i$2[1]
		})).sort((a$1, b$2) => a$1.color === defaultColor ? -1 : b$2.color === defaultColor ? 1 : 0);
		if (themes.length === 0) throw new ShikiError$1("`themes` option must not be empty");
		const themeTokens = codeToTokensWithThemes(primitive, code, options, codeToTokensBase$1);
		grammarState = getLastGrammarStateFromMap(themeTokens);
		if (defaultColor && DEFAULT_COLOR_LIGHT_DARK !== defaultColor && !themes.find((t) => t.color === defaultColor)) throw new ShikiError$1(`\`themes\` option must contain the defaultColor key \`${defaultColor}\``);
		const themeRegs = themes.map((t) => primitive.getTheme(t.theme));
		const themesOrder = themes.map((t) => t.color);
		tokens = themeTokens.map((line) => line.map((token$1) => flatTokenVariants(token$1, themesOrder, cssVariablePrefix, defaultColor, colorsRendering)));
		if (grammarState) setLastGrammarStateToMap(tokens, grammarState);
		const themeColorReplacements = themes.map((t) => resolveColorReplacements(t.theme, options));
		fg = mapThemeColors(themes, themeRegs, themeColorReplacements, cssVariablePrefix, defaultColor, "fg", colorsRendering);
		bg = mapThemeColors(themes, themeRegs, themeColorReplacements, cssVariablePrefix, defaultColor, "bg", colorsRendering);
		themeName = `shiki-themes ${themeRegs.map((t) => t.name).join(" ")}`;
		rootStyle = defaultColor ? void 0 : [fg, bg].join(";");
	} else if ("theme" in options) {
		const colorReplacements = resolveColorReplacements(options.theme, options);
		tokens = codeToTokensBase$1(primitive, code, options);
		const _theme = primitive.getTheme(options.theme);
		bg = applyColorReplacements(_theme.bg, colorReplacements);
		fg = applyColorReplacements(_theme.fg, colorReplacements);
		themeName = _theme.name;
		grammarState = getLastGrammarStateFromMap(tokens);
	} else throw new ShikiError$1("Invalid options, either `theme` or `themes` must be provided");
	return {
		tokens,
		fg,
		bg,
		themeName,
		rootStyle,
		grammarState
	};
}
function mapThemeColors(themes, themeRegs, themeColorReplacements, cssVariablePrefix, defaultColor, property, colorsRendering) {
	return themes.map((t, idx) => {
		const value = applyColorReplacements(themeRegs[idx][property], themeColorReplacements[idx]) || "inherit";
		const cssVar = `${cssVariablePrefix + t.color}${property === "bg" ? "-bg" : ""}:${value}`;
		if (idx === 0 && defaultColor) {
			if (defaultColor === DEFAULT_COLOR_LIGHT_DARK && themes.length > 1) {
				const lightIndex = themes.findIndex((t$1) => t$1.color === "light");
				const darkIndex = themes.findIndex((t$1) => t$1.color === "dark");
				if (lightIndex === -1 || darkIndex === -1) throw new ShikiError$1("When using `defaultColor: \"light-dark()\"`, you must provide both `light` and `dark` themes");
				return `light-dark(${applyColorReplacements(themeRegs[lightIndex][property], themeColorReplacements[lightIndex]) || "inherit"}, ${applyColorReplacements(themeRegs[darkIndex][property], themeColorReplacements[darkIndex]) || "inherit"});${cssVar}`;
			}
			return value;
		}
		if (colorsRendering === "css-vars") return cssVar;
		return null;
	}).filter((i$2) => !!i$2).join(";");
}
function codeToHast(primitive, code, options, transformerContext = {
	meta: {},
	options,
	codeToHast: (_code, _options) => codeToHast(primitive, _code, _options),
	codeToTokens: (_code, _options) => codeToTokens(primitive, _code, _options)
}) {
	let input = code;
	for (const transformer of getTransformers(options)) input = transformer.preprocess?.call(transformerContext, input, options) || input;
	let { tokens, fg, bg, themeName, rootStyle, grammarState } = codeToTokens(primitive, input, options);
	const { mergeWhitespaces = true, mergeSameStyleTokens = false } = options;
	if (mergeWhitespaces === true) tokens = mergeWhitespaceTokens(tokens);
	else if (mergeWhitespaces === "never") tokens = splitWhitespaceTokens(tokens);
	if (mergeSameStyleTokens) tokens = mergeAdjacentStyledTokens(tokens);
	const contextSource = {
		...transformerContext,
		get source() {
			return input;
		}
	};
	for (const transformer of getTransformers(options)) tokens = transformer.tokens?.call(contextSource, tokens) || tokens;
	return tokensToHast(tokens, {
		...options,
		fg,
		bg,
		themeName,
		rootStyle: options.rootStyle === false ? false : options.rootStyle ?? rootStyle
	}, contextSource, grammarState);
}
function tokensToHast(tokens, options, transformerContext, grammarState = getLastGrammarStateFromMap(tokens)) {
	const transformers = getTransformers(options);
	const lines = [];
	const root$1 = {
		type: "root",
		children: []
	};
	const { structure = "classic", tabindex = "0" } = options;
	const properties = { class: `shiki ${options.themeName || ""}` };
	if (options.rootStyle !== false) if (options.rootStyle != null) properties.style = options.rootStyle;
	else properties.style = `background-color:${options.bg};color:${options.fg}`;
	if (tabindex !== false && tabindex != null) properties.tabindex = tabindex.toString();
	for (const [key$1, value] of Object.entries(options.meta || {})) if (!key$1.startsWith("_")) properties[key$1] = value;
	let preNode = {
		type: "element",
		tagName: "pre",
		properties,
		children: [],
		data: options.data
	};
	let codeNode = {
		type: "element",
		tagName: "code",
		properties: {},
		children: lines
	};
	const lineNodes = [];
	const context = {
		...transformerContext,
		structure,
		addClassToHast,
		get source() {
			return transformerContext.source;
		},
		get tokens() {
			return tokens;
		},
		get options() {
			return options;
		},
		get root() {
			return root$1;
		},
		get pre() {
			return preNode;
		},
		get code() {
			return codeNode;
		},
		get lines() {
			return lineNodes;
		}
	};
	tokens.forEach((line, idx) => {
		if (idx) {
			if (structure === "inline") root$1.children.push({
				type: "element",
				tagName: "br",
				properties: {},
				children: []
			});
			else if (structure === "classic") lines.push({
				type: "text",
				value: "\n"
			});
		}
		let lineNode = {
			type: "element",
			tagName: "span",
			properties: { class: "line" },
			children: []
		};
		let col = 0;
		for (const token$1 of line) {
			let tokenNode = {
				type: "element",
				tagName: "span",
				properties: { ...token$1.htmlAttrs },
				children: [{
					type: "text",
					value: token$1.content
				}]
			};
			const style = stringifyTokenStyle(token$1.htmlStyle || getTokenStyleObject(token$1));
			if (style) tokenNode.properties.style = style;
			for (const transformer of transformers) tokenNode = transformer?.span?.call(context, tokenNode, idx + 1, col, lineNode, token$1) || tokenNode;
			if (structure === "inline") root$1.children.push(tokenNode);
			else if (structure === "classic") lineNode.children.push(tokenNode);
			col += token$1.content.length;
		}
		if (structure === "classic") {
			for (const transformer of transformers) lineNode = transformer?.line?.call(context, lineNode, idx + 1) || lineNode;
			lineNodes.push(lineNode);
			lines.push(lineNode);
		} else if (structure === "inline") lineNodes.push(lineNode);
	});
	if (structure === "classic") {
		for (const transformer of transformers) codeNode = transformer?.code?.call(context, codeNode) || codeNode;
		preNode.children.push(codeNode);
		for (const transformer of transformers) preNode = transformer?.pre?.call(context, preNode) || preNode;
		root$1.children.push(preNode);
	} else if (structure === "inline") {
		const syntheticLines = [];
		let currentLine = {
			type: "element",
			tagName: "span",
			properties: { class: "line" },
			children: []
		};
		for (const child of root$1.children) if (child.type === "element" && child.tagName === "br") {
			syntheticLines.push(currentLine);
			currentLine = {
				type: "element",
				tagName: "span",
				properties: { class: "line" },
				children: []
			};
		} else if (child.type === "element" || child.type === "text") currentLine.children.push(child);
		syntheticLines.push(currentLine);
		let transformedCode = {
			type: "element",
			tagName: "code",
			properties: {},
			children: syntheticLines
		};
		for (const transformer of transformers) transformedCode = transformer?.code?.call(context, transformedCode) || transformedCode;
		root$1.children = [];
		for (let i$2 = 0; i$2 < transformedCode.children.length; i$2++) {
			if (i$2 > 0) root$1.children.push({
				type: "element",
				tagName: "br",
				properties: {},
				children: []
			});
			const line = transformedCode.children[i$2];
			if (line.type === "element") root$1.children.push(...line.children);
		}
	}
	let result = root$1;
	for (const transformer of transformers) result = transformer?.root?.call(context, result) || result;
	if (grammarState) setLastGrammarStateToMap(result, grammarState);
	return result;
}
function mergeWhitespaceTokens(tokens) {
	return tokens.map((line) => {
		const newLine = [];
		let carryOnContent = "";
		let firstOffset;
		line.forEach((token$1, idx) => {
			const couldMerge = !(token$1.fontStyle && (token$1.fontStyle & FontStyle.Underline || token$1.fontStyle & FontStyle.Strikethrough));
			if (couldMerge && token$1.content.match(/^\s+$/) && line[idx + 1]) {
				if (firstOffset === void 0) firstOffset = token$1.offset;
				carryOnContent += token$1.content;
			} else if (carryOnContent) {
				if (couldMerge) newLine.push({
					...token$1,
					offset: firstOffset,
					content: carryOnContent + token$1.content
				});
				else newLine.push({
					content: carryOnContent,
					offset: firstOffset
				}, token$1);
				firstOffset = void 0;
				carryOnContent = "";
			} else newLine.push(token$1);
		});
		return newLine;
	});
}
function splitWhitespaceTokens(tokens) {
	return tokens.map((line) => {
		return line.flatMap((token$1) => {
			if (token$1.content.match(/^\s+$/)) return token$1;
			const match = token$1.content.match(/^(\s*)(.*?)(\s*)$/);
			if (!match) return token$1;
			const [, leading, content, trailing] = match;
			if (!leading && !trailing) return token$1;
			const expanded = [{
				...token$1,
				offset: token$1.offset + leading.length,
				content
			}];
			if (leading) expanded.unshift({
				content: leading,
				offset: token$1.offset
			});
			if (trailing) expanded.push({
				content: trailing,
				offset: token$1.offset + leading.length + content.length
			});
			return expanded;
		});
	});
}
function mergeAdjacentStyledTokens(tokens) {
	return tokens.map((line) => {
		const newLine = [];
		for (const token$1 of line) {
			if (newLine.length === 0) {
				newLine.push({ ...token$1 });
				continue;
			}
			const prevToken = newLine[newLine.length - 1];
			const prevStyle = stringifyTokenStyle(prevToken.htmlStyle || getTokenStyleObject(prevToken));
			const currentStyle = stringifyTokenStyle(token$1.htmlStyle || getTokenStyleObject(token$1));
			const isPrevDecorated = prevToken.fontStyle && (prevToken.fontStyle & FontStyle.Underline || prevToken.fontStyle & FontStyle.Strikethrough);
			const isDecorated = token$1.fontStyle && (token$1.fontStyle & FontStyle.Underline || token$1.fontStyle & FontStyle.Strikethrough);
			if (!isPrevDecorated && !isDecorated && prevStyle === currentStyle) prevToken.content += token$1.content;
			else newLine.push({ ...token$1 });
		}
		return newLine;
	});
}
const hastToHtml = toHtml;
/**
* Get highlighted code in HTML.
*/
function codeToHtml(primitive, code, options) {
	const context = {
		meta: {},
		options,
		codeToHast: (_code, _options) => codeToHast(primitive, _code, _options),
		codeToTokens: (_code, _options) => codeToTokens(primitive, _code, _options)
	};
	let result = hastToHtml(codeToHast(primitive, code, options, context));
	for (const transformer of getTransformers(options)) result = transformer.postprocess?.call(context, result, options) || result;
	return result;
}
/**
* Create a Shiki core highlighter instance, with no languages or themes bundled.
* Wasm and each language and theme must be loaded manually.
*
* @see http://shiki.style/guide/bundles#fine-grained-bundle
*/
async function createHighlighterCore(options) {
	const primitive = await createShikiPrimitiveAsync(options);
	return {
		getLastGrammarState: (...args) => getLastGrammarState(primitive, ...args),
		codeToTokensBase: (code, options$1) => codeToTokensBase$1(primitive, code, options$1),
		codeToTokensWithThemes: (code, options$1) => codeToTokensWithThemes(primitive, code, options$1),
		codeToTokens: (code, options$1) => codeToTokens(primitive, code, options$1),
		codeToHast: (code, options$1) => codeToHast(primitive, code, options$1),
		codeToHtml: (code, options$1) => codeToHtml(primitive, code, options$1),
		getBundledLanguages: () => ({}),
		getBundledThemes: () => ({}),
		...primitive,
		getInternalContext: () => primitive
	};
}
/**
* Create a Shiki core highlighter instance, with no languages or themes bundled.
* Wasm and each language and theme must be loaded manually.
*
* Synchronous version of `createHighlighterCore`, which requires to provide the engine and all themes and languages upfront.
*
* @see http://shiki.style/guide/bundles#fine-grained-bundle
*/
function createHighlighterCoreSync(options) {
	const internal = createShikiPrimitive(options);
	return {
		getLastGrammarState: (...args) => getLastGrammarState(internal, ...args),
		codeToTokensBase: (code, options$1) => codeToTokensBase$1(internal, code, options$1),
		codeToTokensWithThemes: (code, options$1) => codeToTokensWithThemes(internal, code, options$1),
		codeToTokens: (code, options$1) => codeToTokens(internal, code, options$1),
		codeToHast: (code, options$1) => codeToHast(internal, code, options$1),
		codeToHtml: (code, options$1) => codeToHtml(internal, code, options$1),
		getBundledLanguages: () => ({}),
		getBundledThemes: () => ({}),
		...internal,
		getInternalContext: () => internal
	};
}
function makeSingletonHighlighterCore(createHighlighter) {
	let _shiki;
	async function getSingletonHighlighterCore$1(options) {
		if (!_shiki) {
			_shiki = createHighlighter({
				...options,
				themes: options.themes || [],
				langs: options.langs || []
			});
			return _shiki;
		} else {
			const s$1 = await _shiki;
			await Promise.all([s$1.loadTheme(...options.themes || []), s$1.loadLanguage(...options.langs || [])]);
			return s$1;
		}
	}
	return getSingletonHighlighterCore$1;
}
const getSingletonHighlighterCore = /* @__PURE__ */ makeSingletonHighlighterCore(createHighlighterCore);
function createBundledHighlighter(options) {
	const bundledLanguages = options.langs;
	const bundledThemes = options.themes;
	const engine = options.engine;
	async function createHighlighter(options$1) {
		function resolveLang(lang) {
			if (typeof lang === "string") {
				lang = options$1.langAlias?.[lang] || lang;
				if (isSpecialLang(lang)) return [];
				const bundle = bundledLanguages[lang];
				if (!bundle) throw new ShikiError$1(`Language \`${lang}\` is not included in this bundle. You may want to load it from external source.`);
				return bundle;
			}
			return lang;
		}
		function resolveTheme(theme) {
			if (isSpecialTheme(theme)) return "none";
			if (typeof theme === "string") {
				const bundle = bundledThemes[theme];
				if (!bundle) throw new ShikiError$1(`Theme \`${theme}\` is not included in this bundle. You may want to load it from external source.`);
				return bundle;
			}
			return theme;
		}
		const _themes = (options$1.themes ?? []).map((i$2) => resolveTheme(i$2));
		const langs = (options$1.langs ?? []).map((i$2) => resolveLang(i$2));
		const core$1 = await createHighlighterCore({
			engine: options$1.engine ?? engine(),
			...options$1,
			themes: _themes,
			langs
		});
		return {
			...core$1,
			loadLanguage(...langs$1) {
				return core$1.loadLanguage(...langs$1.map(resolveLang));
			},
			loadTheme(...themes) {
				return core$1.loadTheme(...themes.map(resolveTheme));
			},
			getBundledLanguages() {
				return bundledLanguages;
			},
			getBundledThemes() {
				return bundledThemes;
			}
		};
	}
	return createHighlighter;
}
function makeSingletonHighlighter(createHighlighter) {
	let _shiki;
	async function getSingletonHighlighter(options = {}) {
		if (!_shiki) {
			_shiki = createHighlighter({
				...options,
				themes: [],
				langs: []
			});
			const s$1 = await _shiki;
			await Promise.all([s$1.loadTheme(...options.themes || []), s$1.loadLanguage(...options.langs || [])]);
			return s$1;
		} else {
			const s$1 = await _shiki;
			await Promise.all([s$1.loadTheme(...options.themes || []), s$1.loadLanguage(...options.langs || [])]);
			return s$1;
		}
	}
	return getSingletonHighlighter;
}
function createSingletonShorthands(createHighlighter, config) {
	const getSingletonHighlighter = makeSingletonHighlighter(createHighlighter);
	async function get(code, options) {
		const shiki = await getSingletonHighlighter({
			langs: [options.lang],
			themes: "theme" in options ? [options.theme] : Object.values(options.themes)
		});
		const langs = await config?.guessEmbeddedLanguages?.(code, options.lang, shiki);
		if (langs) await shiki.loadLanguage(...langs);
		return shiki;
	}
	return {
		getSingletonHighlighter(options) {
			return getSingletonHighlighter(options);
		},
		async codeToHtml(code, options) {
			return (await get(code, options)).codeToHtml(code, options);
		},
		async codeToHast(code, options) {
			return (await get(code, options)).codeToHast(code, options);
		},
		async codeToTokens(code, options) {
			return (await get(code, options)).codeToTokens(code, options);
		},
		async codeToTokensBase(code, options) {
			return (await get(code, options)).codeToTokensBase(code, options);
		},
		async codeToTokensWithThemes(code, options) {
			return (await get(code, options)).codeToTokensWithThemes(code, options);
		},
		async getLastGrammarState(code, options) {
			return (await getSingletonHighlighter({
				langs: [options.lang],
				themes: [options.theme]
			})).getLastGrammarState(code, options);
		}
	};
}
/**
* A factory function to create a css-variable-based theme
*
* @see https://shiki.style/guide/theme-colors#css-variables-theme
*/
function createCssVariablesTheme(options = {}) {
	const { name = "css-variables", variablePrefix = "--shiki-", fontStyle = true } = options;
	const variable = (name$1) => {
		if (options.variableDefaults?.[name$1]) return `var(${variablePrefix}${name$1}, ${options.variableDefaults[name$1]})`;
		return `var(${variablePrefix}${name$1})`;
	};
	const theme = {
		name,
		type: "dark",
		colors: {
			"editor.foreground": variable("foreground"),
			"editor.background": variable("background"),
			"terminal.ansiBlack": variable("ansi-black"),
			"terminal.ansiRed": variable("ansi-red"),
			"terminal.ansiGreen": variable("ansi-green"),
			"terminal.ansiYellow": variable("ansi-yellow"),
			"terminal.ansiBlue": variable("ansi-blue"),
			"terminal.ansiMagenta": variable("ansi-magenta"),
			"terminal.ansiCyan": variable("ansi-cyan"),
			"terminal.ansiWhite": variable("ansi-white"),
			"terminal.ansiBrightBlack": variable("ansi-bright-black"),
			"terminal.ansiBrightRed": variable("ansi-bright-red"),
			"terminal.ansiBrightGreen": variable("ansi-bright-green"),
			"terminal.ansiBrightYellow": variable("ansi-bright-yellow"),
			"terminal.ansiBrightBlue": variable("ansi-bright-blue"),
			"terminal.ansiBrightMagenta": variable("ansi-bright-magenta"),
			"terminal.ansiBrightCyan": variable("ansi-bright-cyan"),
			"terminal.ansiBrightWhite": variable("ansi-bright-white")
		},
		tokenColors: [
			{
				scope: [
					"keyword.operator.accessor",
					"meta.group.braces.round.function.arguments",
					"meta.template.expression",
					"markup.fenced_code meta.embedded.block"
				],
				settings: { foreground: variable("foreground") }
			},
			{
				scope: "emphasis",
				settings: { fontStyle: "italic" }
			},
			{
				scope: [
					"strong",
					"markup.heading.markdown",
					"markup.bold.markdown"
				],
				settings: { fontStyle: "bold" }
			},
			{
				scope: ["markup.italic.markdown"],
				settings: { fontStyle: "italic" }
			},
			{
				scope: "meta.link.inline.markdown",
				settings: {
					fontStyle: "underline",
					foreground: variable("token-link")
				}
			},
			{
				scope: [
					"string",
					"markup.fenced_code",
					"markup.inline"
				],
				settings: { foreground: variable("token-string") }
			},
			{
				scope: ["comment", "string.quoted.docstring.multi"],
				settings: { foreground: variable("token-comment") }
			},
			{
				scope: [
					"constant.numeric",
					"constant.language",
					"constant.other.placeholder",
					"constant.character.format.placeholder",
					"variable.language.this",
					"variable.other.object",
					"variable.other.class",
					"variable.other.constant",
					"meta.property-name",
					"meta.property-value",
					"support"
				],
				settings: { foreground: variable("token-constant") }
			},
			{
				scope: [
					"keyword",
					"storage.modifier",
					"storage.type",
					"storage.control.clojure",
					"entity.name.function.clojure",
					"entity.name.tag.yaml",
					"support.function.node",
					"support.type.property-name.json",
					"punctuation.separator.key-value",
					"punctuation.definition.template-expression"
				],
				settings: { foreground: variable("token-keyword") }
			},
			{
				scope: "variable.parameter.function",
				settings: { foreground: variable("token-parameter") }
			},
			{
				scope: [
					"support.function",
					"entity.name.type",
					"entity.other.inherited-class",
					"meta.function-call",
					"meta.instance.constructor",
					"entity.other.attribute-name",
					"entity.name.function",
					"constant.keyword.clojure"
				],
				settings: { foreground: variable("token-function") }
			},
			{
				scope: [
					"entity.name.tag",
					"string.quoted",
					"string.regexp",
					"string.interpolated",
					"string.template",
					"string.unquoted.plain.out.yaml",
					"keyword.other.template"
				],
				settings: { foreground: variable("token-string-expression") }
			},
			{
				scope: [
					"punctuation.definition.arguments",
					"punctuation.definition.dict",
					"punctuation.separator",
					"meta.function-call.arguments"
				],
				settings: { foreground: variable("token-punctuation") }
			},
			{
				scope: ["markup.underline.link", "punctuation.definition.metadata.markdown"],
				settings: { foreground: variable("token-link") }
			},
			{
				scope: ["beginning.punctuation.definition.list.markdown"],
				settings: { foreground: variable("token-string") }
			},
			{
				scope: [
					"punctuation.definition.string.begin.markdown",
					"punctuation.definition.string.end.markdown",
					"string.other.link.title.markdown",
					"string.other.link.description.markdown"
				],
				settings: { foreground: variable("token-keyword") }
			},
			{
				scope: [
					"markup.inserted",
					"meta.diff.header.to-file",
					"punctuation.definition.inserted"
				],
				settings: { foreground: variable("token-inserted") }
			},
			{
				scope: [
					"markup.deleted",
					"meta.diff.header.from-file",
					"punctuation.definition.deleted"
				],
				settings: { foreground: variable("token-deleted") }
			},
			{
				scope: ["markup.changed", "punctuation.definition.changed"],
				settings: { foreground: variable("token-changed") }
			}
		]
	};
	if (!fontStyle) theme.tokenColors = theme.tokenColors?.map((tokenColor) => {
		if (tokenColor.settings?.fontStyle) delete tokenColor.settings.fontStyle;
		return tokenColor;
	});
	return theme;
}

//#endregion
//#region ../../node_modules/.bun/@shikijs+engine-javascript@4.0.2/node_modules/@shikijs/engine-javascript/dist/scanner-BFcBmQR1.mjs
const MAX = 4294967295;
var JavaScriptScanner = class {
	regexps;
	constructor(patterns, options = {}) {
		this.patterns = patterns;
		this.options = options;
		const { forgiving = false, cache, regexConstructor } = options;
		if (!regexConstructor) throw new Error("Option `regexConstructor` is not provided");
		this.regexps = patterns.map((p$1) => {
			if (typeof p$1 !== "string") return p$1;
			const cached = cache?.get(p$1);
			if (cached) {
				if (cached instanceof RegExp) return cached;
				if (forgiving) return null;
				throw cached;
			}
			try {
				const regex = regexConstructor(p$1);
				cache?.set(p$1, regex);
				return regex;
			} catch (e) {
				cache?.set(p$1, e);
				if (forgiving) return null;
				throw e;
			}
		});
	}
	findNextMatchSync(string, startPosition, _options) {
		const str = typeof string === "string" ? string : string.content;
		const pending = [];
		function toResult(index, match, offset = 0) {
			return {
				index,
				captureIndices: match.indices.map((indice) => {
					if (indice == null) return {
						start: MAX,
						end: MAX,
						length: 0
					};
					return {
						start: indice[0] + offset,
						end: indice[1] + offset,
						length: indice[1] - indice[0]
					};
				})
			};
		}
		for (let i$2 = 0; i$2 < this.regexps.length; i$2++) {
			const regexp = this.regexps[i$2];
			if (!regexp) continue;
			try {
				regexp.lastIndex = startPosition;
				const match = regexp.exec(str);
				if (!match) continue;
				if (match.index === startPosition) return toResult(i$2, match, 0);
				pending.push([
					i$2,
					match,
					0
				]);
			} catch (e) {
				if (this.options.forgiving) continue;
				throw e;
			}
		}
		if (pending.length) {
			const minIndex = Math.min(...pending.map((m$2) => m$2[1].index));
			for (const [i$2, match, offset] of pending) if (match.index === minIndex) return toResult(i$2, match, offset);
		}
		return null;
	}
};

//#endregion
//#region ../../node_modules/.bun/oniguruma-parser@0.12.1/node_modules/oniguruma-parser/dist/utils.js
function r$2(e) {
	if ([...e].length !== 1) throw new Error(`Expected "${e}" to be a single code point`);
	return e.codePointAt(0);
}
function l$1(e, t, n) {
	return e.has(t) || e.set(t, n), e.get(t);
}
const i = new Set([
	"alnum",
	"alpha",
	"ascii",
	"blank",
	"cntrl",
	"digit",
	"graph",
	"lower",
	"print",
	"punct",
	"space",
	"upper",
	"word",
	"xdigit"
]), o$1 = String.raw;
function u(e, t) {
	if (e == null) throw new Error(t ?? "Value expected");
	return e;
}

//#endregion
//#region ../../node_modules/.bun/oniguruma-parser@0.12.1/node_modules/oniguruma-parser/dist/tokenizer/tokenize.js
const m$1 = o$1`\[\^?`, b$1 = `c.? | C(?:-.?)?|${o$1`[pP]\{(?:\^?[-\x20_]*[A-Za-z][-\x20\w]*\})?`}|${o$1`x[89A-Fa-f]\p{AHex}(?:\\x[89A-Fa-f]\p{AHex})*`}|${o$1`u(?:\p{AHex}{4})? | x\{[^\}]*\}? | x\p{AHex}{0,2}`}|${o$1`o\{[^\}]*\}?`}|${o$1`\d{1,3}`}`, y$1 = /[?*+][?+]?|\{(?:\d+(?:,\d*)?|,\d+)\}\??/, C$1 = new RegExp(o$1`
  \\ (?:
    ${b$1}
    | [gk]<[^>]*>?
    | [gk]'[^']*'?
    | .
  )
  | \( (?:
    \? (?:
      [:=!>({]
      | <[=!]
      | <[^>]*>
      | '[^']*'
      | ~\|?
      | #(?:[^)\\]|\\.?)*
      | [^:)]*[:)]
    )?
    | \*[^\)]*\)?
  )?
  | (?:${y$1.source})+
  | ${m$1}
  | .
`.replace(/\s+/g, ""), "gsu"), T$1 = new RegExp(o$1`
  \\ (?:
    ${b$1}
    | .
  )
  | \[:(?:\^?\p{Alpha}+|\^):\]
  | ${m$1}
  | &&
  | .
`.replace(/\s+/g, ""), "gsu");
function M(e, n = {}) {
	const t = {
		flags: "",
		...n,
		rules: {
			captureGroup: !1,
			singleline: !1,
			...n.rules
		}
	};
	if (typeof e != "string") throw new Error("String expected as pattern");
	const o$2 = Y(t.flags), s$1 = [o$2.extended], a$1 = {
		captureGroup: t.rules.captureGroup,
		getCurrentModX() {
			return s$1.at(-1);
		},
		numOpenGroups: 0,
		popModX() {
			s$1.pop();
		},
		pushModX(u$1) {
			s$1.push(u$1);
		},
		replaceCurrentModX(u$1) {
			s$1[s$1.length - 1] = u$1;
		},
		singleline: t.rules.singleline
	};
	let r$3 = [], i$2;
	for (C$1.lastIndex = 0; i$2 = C$1.exec(e);) {
		const u$1 = F$1(a$1, e, i$2[0], C$1.lastIndex);
		u$1.tokens ? r$3.push(...u$1.tokens) : u$1.token && r$3.push(u$1.token), u$1.lastIndex !== void 0 && (C$1.lastIndex = u$1.lastIndex);
	}
	const l$2 = [];
	let c = 0;
	r$3.filter((u$1) => u$1.type === "GroupOpen").forEach((u$1) => {
		u$1.kind === "capturing" ? u$1.number = ++c : u$1.raw === "(" && l$2.push(u$1);
	}), c || l$2.forEach((u$1, S$1) => {
		u$1.kind = "capturing", u$1.number = S$1 + 1;
	});
	const g = c || l$2.length;
	return {
		tokens: r$3.map((u$1) => u$1.type === "EscapedNumber" ? ee$1(u$1, g) : u$1).flat(),
		flags: o$2
	};
}
function F$1(e, n, t, o$2) {
	const [s$1, a$1] = t;
	if (t === "[" || t === "[^") {
		const r$3 = K$1(n, t, o$2);
		return {
			tokens: r$3.tokens,
			lastIndex: r$3.lastIndex
		};
	}
	if (s$1 === "\\") {
		if ("AbBGyYzZ".includes(a$1)) return { token: w$1(t, t) };
		if (/^\\g[<']/.test(t)) {
			if (!/^\\g(?:<[^>]+>|'[^']+')$/.test(t)) throw new Error(`Invalid group name "${t}"`);
			return { token: R$1(t) };
		}
		if (/^\\k[<']/.test(t)) {
			if (!/^\\k(?:<[^>]+>|'[^']+')$/.test(t)) throw new Error(`Invalid group name "${t}"`);
			return { token: A$1(t) };
		}
		if (a$1 === "K") return { token: I$1("keep", t) };
		if (a$1 === "N" || a$1 === "R") return { token: k$1("newline", t, { negate: a$1 === "N" }) };
		if (a$1 === "O") return { token: k$1("any", t) };
		if (a$1 === "X") return { token: k$1("text_segment", t) };
		const r$3 = x(t, { inCharClass: !1 });
		return Array.isArray(r$3) ? { tokens: r$3 } : { token: r$3 };
	}
	if (s$1 === "(") {
		if (a$1 === "*") return { token: j(t) };
		if (t === "(?{") throw new Error(`Unsupported callout "${t}"`);
		if (t.startsWith("(?#")) {
			if (n[o$2] !== ")") throw new Error("Unclosed comment group \"(?#\"");
			return { lastIndex: o$2 + 1 };
		}
		if (/^\(\?[-imx]+[:)]$/.test(t)) return { token: L$1(t, e) };
		if (e.pushModX(e.getCurrentModX()), e.numOpenGroups++, t === "(" && !e.captureGroup || t === "(?:") return { token: f$1("group", t) };
		if (t === "(?>") return { token: f$1("atomic", t) };
		if (t === "(?=" || t === "(?!" || t === "(?<=" || t === "(?<!") return { token: f$1(t[2] === "<" ? "lookbehind" : "lookahead", t, { negate: t.endsWith("!") }) };
		if (t === "(" && e.captureGroup || t.startsWith("(?<") && t.endsWith(">") || t.startsWith("(?'") && t.endsWith("'")) return { token: f$1("capturing", t, { ...t !== "(" && { name: t.slice(3, -1) } }) };
		if (t.startsWith("(?~")) {
			if (t === "(?~|") throw new Error(`Unsupported absence function kind "${t}"`);
			return { token: f$1("absence_repeater", t) };
		}
		throw t === "(?(" ? new Error(`Unsupported conditional "${t}"`) : new Error(`Invalid or unsupported group option "${t}"`);
	}
	if (t === ")") {
		if (e.popModX(), e.numOpenGroups--, e.numOpenGroups < 0) throw new Error("Unmatched \")\"");
		return { token: Q$1(t) };
	}
	if (e.getCurrentModX()) {
		if (t === "#") {
			const r$3 = n.indexOf(`
`, o$2);
			return { lastIndex: r$3 === -1 ? n.length : r$3 };
		}
		if (/^\s$/.test(t)) {
			const r$3 = /\s+/y;
			return r$3.lastIndex = o$2, { lastIndex: r$3.exec(n) ? r$3.lastIndex : o$2 };
		}
	}
	if (t === ".") return { token: k$1("dot", t) };
	if (t === "^" || t === "$") {
		const r$3 = e.singleline ? {
			"^": o$1`\A`,
			$: o$1`\Z`
		}[t] : t;
		return { token: w$1(r$3, t) };
	}
	return t === "|" ? { token: P$1(t) } : y$1.test(t) ? { tokens: te$1(t) } : { token: d(r$2(t), t) };
}
function K$1(e, n, t) {
	const o$2 = [E$1(n[1] === "^", n)];
	let s$1 = 1, a$1;
	for (T$1.lastIndex = t; a$1 = T$1.exec(e);) {
		const r$3 = a$1[0];
		if (r$3[0] === "[" && r$3[1] !== ":") s$1++, o$2.push(E$1(r$3[1] === "^", r$3));
		else if (r$3 === "]") {
			if (o$2.at(-1).type === "CharacterClassOpen") o$2.push(d(93, r$3));
			else if (s$1--, o$2.push(z$1(r$3)), !s$1) break;
		} else {
			const i$2 = X$1(r$3);
			Array.isArray(i$2) ? o$2.push(...i$2) : o$2.push(i$2);
		}
	}
	return {
		tokens: o$2,
		lastIndex: T$1.lastIndex || e.length
	};
}
function X$1(e) {
	if (e[0] === "\\") return x(e, { inCharClass: !0 });
	if (e[0] === "[") {
		const n = /\[:(?<negate>\^?)(?<name>[a-z]+):\]/.exec(e);
		if (!n || !i.has(n.groups.name)) throw new Error(`Invalid POSIX class "${e}"`);
		return k$1("posix", e, {
			value: n.groups.name,
			negate: !!n.groups.negate
		});
	}
	return e === "-" ? U$1(e) : e === "&&" ? H(e) : d(r$2(e), e);
}
function x(e, { inCharClass: n }) {
	const t = e[1];
	if (t === "c" || t === "C") return Z(e);
	if ("dDhHsSwW".includes(t)) return q(e);
	if (e.startsWith(o$1`\o{`)) throw new Error(`Incomplete, invalid, or unsupported octal code point "${e}"`);
	if (/^\\[pP]\{/.test(e)) {
		if (e.length === 3) throw new Error(`Incomplete or invalid Unicode property "${e}"`);
		return V$1(e);
	}
	if (/^\\x[89A-Fa-f]\p{AHex}/u.test(e)) try {
		const o$2 = e.split(/\\x/).slice(1).map((i$2) => parseInt(i$2, 16)), s$1 = new TextDecoder("utf-8", {
			ignoreBOM: !0,
			fatal: !0
		}).decode(new Uint8Array(o$2)), a$1 = new TextEncoder();
		return [...s$1].map((i$2) => {
			const l$2 = [...a$1.encode(i$2)].map((c) => `\\x${c.toString(16)}`).join("");
			return d(r$2(i$2), l$2);
		});
	} catch {
		throw new Error(`Multibyte code "${e}" incomplete or invalid in Oniguruma`);
	}
	if (t === "u" || t === "x") return d(J$1(e), e);
	if ($$1.has(t)) return d($$1.get(t), e);
	if (/\d/.test(t)) return W$1(n, e);
	if (e === "\\") throw new Error(o$1`Incomplete escape "\"`);
	if (t === "M") throw new Error(`Unsupported meta "${e}"`);
	if ([...e].length === 2) return d(e.codePointAt(1), e);
	throw new Error(`Unexpected escape "${e}"`);
}
function P$1(e) {
	return {
		type: "Alternator",
		raw: e
	};
}
function w$1(e, n) {
	return {
		type: "Assertion",
		kind: e,
		raw: n
	};
}
function A$1(e) {
	return {
		type: "Backreference",
		raw: e
	};
}
function d(e, n) {
	return {
		type: "Character",
		value: e,
		raw: n
	};
}
function z$1(e) {
	return {
		type: "CharacterClassClose",
		raw: e
	};
}
function U$1(e) {
	return {
		type: "CharacterClassHyphen",
		raw: e
	};
}
function H(e) {
	return {
		type: "CharacterClassIntersector",
		raw: e
	};
}
function E$1(e, n) {
	return {
		type: "CharacterClassOpen",
		negate: e,
		raw: n
	};
}
function k$1(e, n, t = {}) {
	return {
		type: "CharacterSet",
		kind: e,
		...t,
		raw: n
	};
}
function I$1(e, n, t = {}) {
	return e === "keep" ? {
		type: "Directive",
		kind: e,
		raw: n
	} : {
		type: "Directive",
		kind: e,
		flags: u(t.flags),
		raw: n
	};
}
function W$1(e, n) {
	return {
		type: "EscapedNumber",
		inCharClass: e,
		raw: n
	};
}
function Q$1(e) {
	return {
		type: "GroupClose",
		raw: e
	};
}
function f$1(e, n, t = {}) {
	return {
		type: "GroupOpen",
		kind: e,
		...t,
		raw: n
	};
}
function D$1(e, n, t, o$2) {
	return {
		type: "NamedCallout",
		kind: e,
		tag: n,
		arguments: t,
		raw: o$2
	};
}
function _$1(e, n, t, o$2) {
	return {
		type: "Quantifier",
		kind: e,
		min: n,
		max: t,
		raw: o$2
	};
}
function R$1(e) {
	return {
		type: "Subroutine",
		raw: e
	};
}
const B$1 = new Set([
	"COUNT",
	"CMP",
	"ERROR",
	"FAIL",
	"MAX",
	"MISMATCH",
	"SKIP",
	"TOTAL_COUNT"
]), $$1 = new Map([
	["a", 7],
	["b", 8],
	["e", 27],
	["f", 12],
	["n", 10],
	["r", 13],
	["t", 9],
	["v", 11]
]);
function Z(e) {
	const n = e[1] === "c" ? e[2] : e[3];
	if (!n || !/[A-Za-z]/.test(n)) throw new Error(`Unsupported control character "${e}"`);
	return d(r$2(n.toUpperCase()) - 64, e);
}
function L$1(e, n) {
	let { on: t, off: o$2 } = /^\(\?(?<on>[imx]*)(?:-(?<off>[-imx]*))?/.exec(e).groups;
	o$2 ??= "";
	const s$1 = (n.getCurrentModX() || t.includes("x")) && !o$2.includes("x"), a$1 = v(t), r$3 = v(o$2), i$2 = {};
	if (a$1 && (i$2.enable = a$1), r$3 && (i$2.disable = r$3), e.endsWith(")")) return n.replaceCurrentModX(s$1), I$1("flags", e, { flags: i$2 });
	if (e.endsWith(":")) return n.pushModX(s$1), n.numOpenGroups++, f$1("group", e, { ...(a$1 || r$3) && { flags: i$2 } });
	throw new Error(`Unexpected flag modifier "${e}"`);
}
function j(e) {
	const n = /\(\*(?<name>[A-Za-z_]\w*)?(?:\[(?<tag>(?:[A-Za-z_]\w*)?)\])?(?:\{(?<args>[^}]*)\})?\)/.exec(e);
	if (!n) throw new Error(`Incomplete or invalid named callout "${e}"`);
	const { name: t, tag: o$2, args: s$1 } = n.groups;
	if (!t) throw new Error(`Invalid named callout "${e}"`);
	if (o$2 === "") throw new Error(`Named callout tag with empty value not allowed "${e}"`);
	const a$1 = s$1 ? s$1.split(",").filter((g) => g !== "").map((g) => /^[+-]?\d+$/.test(g) ? +g : g) : [], [r$3, i$2, l$2] = a$1, c = B$1.has(t) ? t.toLowerCase() : "custom";
	switch (c) {
		case "fail":
		case "mismatch":
		case "skip":
			if (a$1.length > 0) throw new Error(`Named callout arguments not allowed "${a$1}"`);
			break;
		case "error":
			if (a$1.length > 1) throw new Error(`Named callout allows only one argument "${a$1}"`);
			if (typeof r$3 == "string") throw new Error(`Named callout argument must be a number "${r$3}"`);
			break;
		case "max":
			if (!a$1.length || a$1.length > 2) throw new Error(`Named callout must have one or two arguments "${a$1}"`);
			if (typeof r$3 == "string" && !/^[A-Za-z_]\w*$/.test(r$3)) throw new Error(`Named callout argument one must be a tag or number "${r$3}"`);
			if (a$1.length === 2 && (typeof i$2 == "number" || !/^[<>X]$/.test(i$2))) throw new Error(`Named callout optional argument two must be '<', '>', or 'X' "${i$2}"`);
			break;
		case "count":
		case "total_count":
			if (a$1.length > 1) throw new Error(`Named callout allows only one argument "${a$1}"`);
			if (a$1.length === 1 && (typeof r$3 == "number" || !/^[<>X]$/.test(r$3))) throw new Error(`Named callout optional argument must be '<', '>', or 'X' "${r$3}"`);
			break;
		case "cmp":
			if (a$1.length !== 3) throw new Error(`Named callout must have three arguments "${a$1}"`);
			if (typeof r$3 == "string" && !/^[A-Za-z_]\w*$/.test(r$3)) throw new Error(`Named callout argument one must be a tag or number "${r$3}"`);
			if (typeof i$2 == "number" || !/^(?:[<>!=]=|[<>])$/.test(i$2)) throw new Error(`Named callout argument two must be '==', '!=', '>', '<', '>=', or '<=' "${i$2}"`);
			if (typeof l$2 == "string" && !/^[A-Za-z_]\w*$/.test(l$2)) throw new Error(`Named callout argument three must be a tag or number "${l$2}"`);
			break;
		case "custom": throw new Error(`Undefined callout name "${t}"`);
		default: throw new Error(`Unexpected named callout kind "${c}"`);
	}
	return D$1(c, o$2 ?? null, s$1?.split(",") ?? null, e);
}
function O$1(e) {
	let n = null, t, o$2;
	if (e[0] === "{") {
		const { minStr: s$1, maxStr: a$1 } = /^\{(?<minStr>\d*)(?:,(?<maxStr>\d*))?/.exec(e).groups, r$3 = 1e5;
		if (+s$1 > r$3 || a$1 && +a$1 > r$3) throw new Error("Quantifier value unsupported in Oniguruma");
		if (t = +s$1, o$2 = a$1 === void 0 ? +s$1 : a$1 === "" ? 1 / 0 : +a$1, t > o$2 && (n = "possessive", [t, o$2] = [o$2, t]), e.endsWith("?")) {
			if (n === "possessive") throw new Error("Unsupported possessive interval quantifier chain with \"?\"");
			n = "lazy";
		} else n || (n = "greedy");
	} else t = e[0] === "+" ? 1 : 0, o$2 = e[0] === "?" ? 1 : 1 / 0, n = e[1] === "+" ? "possessive" : e[1] === "?" ? "lazy" : "greedy";
	return _$1(n, t, o$2, e);
}
function q(e) {
	const n = e[1].toLowerCase();
	return k$1({
		d: "digit",
		h: "hex",
		s: "space",
		w: "word"
	}[n], e, { negate: e[1] !== n });
}
function V$1(e) {
	const { p: n, neg: t, value: o$2 } = /^\\(?<p>[pP])\{(?<neg>\^?)(?<value>[^}]+)/.exec(e).groups;
	return k$1("property", e, {
		value: o$2,
		negate: n === "P" && !t || n === "p" && !!t
	});
}
function v(e) {
	const n = {};
	return e.includes("i") && (n.ignoreCase = !0), e.includes("m") && (n.dotAll = !0), e.includes("x") && (n.extended = !0), Object.keys(n).length ? n : null;
}
function Y(e) {
	const n = {
		ignoreCase: !1,
		dotAll: !1,
		extended: !1,
		digitIsAscii: !1,
		posixIsAscii: !1,
		spaceIsAscii: !1,
		wordIsAscii: !1,
		textSegmentMode: null
	};
	for (let t = 0; t < e.length; t++) {
		const o$2 = e[t];
		if (!"imxDPSWy".includes(o$2)) throw new Error(`Invalid flag "${o$2}"`);
		if (o$2 === "y") {
			if (!/^y{[gw]}/.test(e.slice(t))) throw new Error("Invalid or unspecified flag \"y\" mode");
			n.textSegmentMode = e[t + 2] === "g" ? "grapheme" : "word", t += 3;
			continue;
		}
		n[{
			i: "ignoreCase",
			m: "dotAll",
			x: "extended",
			D: "digitIsAscii",
			P: "posixIsAscii",
			S: "spaceIsAscii",
			W: "wordIsAscii"
		}[o$2]] = !0;
	}
	return n;
}
function J$1(e) {
	if (/^(?:\\u(?!\p{AHex}{4})|\\x(?!\p{AHex}{1,2}|\{\p{AHex}{1,8}\}))/u.test(e)) throw new Error(`Incomplete or invalid escape "${e}"`);
	const n = e[2] === "{" ? /^\\x\{\s*(?<hex>\p{AHex}+)/u.exec(e).groups.hex : e.slice(2);
	return parseInt(n, 16);
}
function ee$1(e, n) {
	const { raw: t, inCharClass: o$2 } = e, s$1 = t.slice(1);
	if (!o$2 && (s$1 !== "0" && s$1.length === 1 || s$1[0] !== "0" && +s$1 <= n)) return [A$1(t)];
	const a$1 = [], r$3 = s$1.match(/^[0-7]+|\d/g);
	for (let i$2 = 0; i$2 < r$3.length; i$2++) {
		const l$2 = r$3[i$2];
		let c;
		if (i$2 === 0 && l$2 !== "8" && l$2 !== "9") {
			if (c = parseInt(l$2, 8), c > 127) throw new Error(o$1`Octal encoded byte above 177 unsupported "${t}"`);
		} else c = r$2(l$2);
		a$1.push(d(c, (i$2 === 0 ? "\\" : "") + l$2));
	}
	return a$1;
}
function te$1(e) {
	const n = [], t = new RegExp(y$1, "gy");
	let o$2;
	for (; o$2 = t.exec(e);) {
		const s$1 = o$2[0];
		if (s$1[0] === "{") {
			const a$1 = /^\{(?<min>\d+),(?<max>\d+)\}\??$/.exec(s$1);
			if (a$1) {
				const { min: r$3, max: i$2 } = a$1.groups;
				if (+r$3 > +i$2 && s$1.endsWith("?")) {
					t.lastIndex--, n.push(O$1(s$1.slice(0, -1)));
					continue;
				}
			}
		}
		n.push(O$1(s$1));
	}
	return n;
}

//#endregion
//#region ../../node_modules/.bun/oniguruma-parser@0.12.1/node_modules/oniguruma-parser/dist/parser/node-utils.js
function o(e, t) {
	if (!Array.isArray(e.body)) throw new Error("Expected node with body array");
	if (e.body.length !== 1) return !1;
	const r$3 = e.body[0];
	return !t || Object.keys(t).every((n) => t[n] === r$3[n]);
}
function a(e) {
	return !(!i$1.has(e.type) || e.type === "AbsenceFunction" && e.kind !== "repeater");
}
const i$1 = new Set([
	"AbsenceFunction",
	"CapturingGroup",
	"Group",
	"LookaroundAssertion",
	"Regex"
]);
function s(e) {
	return y.has(e.type);
}
const y = new Set([
	"AbsenceFunction",
	"Backreference",
	"CapturingGroup",
	"Character",
	"CharacterClass",
	"CharacterSet",
	"Group",
	"Quantifier",
	"Subroutine"
]);

//#endregion
//#region ../../node_modules/.bun/oniguruma-parser@0.12.1/node_modules/oniguruma-parser/dist/parser/parse.js
function J(e, r$3 = {}) {
	const n = {
		flags: "",
		normalizeUnknownPropertyNames: !1,
		skipBackrefValidation: !1,
		skipLookbehindValidation: !1,
		skipPropertyNameValidation: !1,
		unicodePropertyMap: null,
		...r$3,
		rules: {
			captureGroup: !1,
			singleline: !1,
			...r$3.rules
		}
	}, t = M(e, {
		flags: n.flags,
		rules: {
			captureGroup: n.rules.captureGroup,
			singleline: n.rules.singleline
		}
	}), s$1 = (p$1, N) => {
		const u$1 = t.tokens[o$2.nextIndex];
		switch (o$2.parent = p$1, o$2.nextIndex++, u$1.type) {
			case "Alternator": return b();
			case "Assertion": return W(u$1);
			case "Backreference": return X(u$1, o$2);
			case "Character": return m(u$1.value, { useLastValid: !!N.isCheckingRangeEnd });
			case "CharacterClassHyphen": return ee(u$1, o$2, N);
			case "CharacterClassOpen": return re(u$1, o$2, N);
			case "CharacterSet": return ne(u$1, o$2);
			case "Directive": return I(u$1.kind, { flags: u$1.flags });
			case "GroupOpen": return te(u$1, o$2, N);
			case "NamedCallout": return U(u$1.kind, u$1.tag, u$1.arguments);
			case "Quantifier": return oe(u$1, o$2);
			case "Subroutine": return ae(u$1, o$2);
			default: throw new Error(`Unexpected token type "${u$1.type}"`);
		}
	}, o$2 = {
		capturingGroups: [],
		hasNumberedRef: !1,
		namedGroupsByName: new Map(),
		nextIndex: 0,
		normalizeUnknownPropertyNames: n.normalizeUnknownPropertyNames,
		parent: null,
		skipBackrefValidation: n.skipBackrefValidation,
		skipLookbehindValidation: n.skipLookbehindValidation,
		skipPropertyNameValidation: n.skipPropertyNameValidation,
		subroutines: [],
		tokens: t.tokens,
		unicodePropertyMap: n.unicodePropertyMap,
		walk: s$1
	}, i$2 = B(T(t.flags));
	let d$1 = i$2.body[0];
	for (; o$2.nextIndex < t.tokens.length;) {
		const p$1 = s$1(d$1, {});
		p$1.type === "Alternative" ? (i$2.body.push(p$1), d$1 = p$1) : d$1.body.push(p$1);
	}
	const { capturingGroups: a$1, hasNumberedRef: l$2, namedGroupsByName: c, subroutines: f$2 } = o$2;
	if (l$2 && c.size && !n.rules.captureGroup) throw new Error("Numbered backref/subroutine not allowed when using named capture");
	for (const { ref: p$1 } of f$2) if (typeof p$1 == "number") {
		if (p$1 > a$1.length) throw new Error("Subroutine uses a group number that's not defined");
		p$1 && (a$1[p$1 - 1].isSubroutined = !0);
	} else if (c.has(p$1)) {
		if (c.get(p$1).length > 1) throw new Error(o$1`Subroutine uses a duplicate group name "\g<${p$1}>"`);
		c.get(p$1)[0].isSubroutined = !0;
	} else throw new Error(o$1`Subroutine uses a group name that's not defined "\g<${p$1}>"`);
	return i$2;
}
function W({ kind: e }) {
	return F(u({
		"^": "line_start",
		$: "line_end",
		"\\A": "string_start",
		"\\b": "word_boundary",
		"\\B": "word_boundary",
		"\\G": "search_start",
		"\\y": "text_segment_boundary",
		"\\Y": "text_segment_boundary",
		"\\z": "string_end",
		"\\Z": "string_end_newline"
	}[e], `Unexpected assertion kind "${e}"`), { negate: e === o$1`\B` || e === o$1`\Y` });
}
function X({ raw: e }, r$3) {
	const n = /^\\k[<']/.test(e), t = n ? e.slice(3, -1) : e.slice(1), s$1 = (o$2, i$2 = !1) => {
		const d$1 = r$3.capturingGroups.length;
		let a$1 = !1;
		if (o$2 > d$1) if (r$3.skipBackrefValidation) a$1 = !0;
		else throw new Error(`Not enough capturing groups defined to the left "${e}"`);
		return r$3.hasNumberedRef = !0, k(i$2 ? d$1 + 1 - o$2 : o$2, { orphan: a$1 });
	};
	if (n) {
		const o$2 = /^(?<sign>-?)0*(?<num>[1-9]\d*)$/.exec(t);
		if (o$2) return s$1(+o$2.groups.num, !!o$2.groups.sign);
		if (/[-+]/.test(t)) throw new Error(`Invalid backref name "${e}"`);
		if (!r$3.namedGroupsByName.has(t)) throw new Error(`Group name not defined to the left "${e}"`);
		return k(t);
	}
	return s$1(+t);
}
function ee(e, r$3, n) {
	const { tokens: t, walk: s$1 } = r$3, o$2 = r$3.parent, i$2 = o$2.body.at(-1), d$1 = t[r$3.nextIndex];
	if (!n.isCheckingRangeEnd && i$2 && i$2.type !== "CharacterClass" && i$2.type !== "CharacterClassRange" && d$1 && d$1.type !== "CharacterClassOpen" && d$1.type !== "CharacterClassClose" && d$1.type !== "CharacterClassIntersector") {
		const a$1 = s$1(o$2, {
			...n,
			isCheckingRangeEnd: !0
		});
		if (i$2.type === "Character" && a$1.type === "Character") return o$2.body.pop(), L(i$2, a$1);
		throw new Error("Invalid character class range");
	}
	return m(r$2("-"));
}
function re({ negate: e }, r$3, n) {
	const { tokens: t, walk: s$1 } = r$3, o$2 = t[r$3.nextIndex], i$2 = [C()];
	let d$1 = z(o$2);
	for (; d$1.type !== "CharacterClassClose";) {
		if (d$1.type === "CharacterClassIntersector") i$2.push(C()), r$3.nextIndex++;
		else {
			const l$2 = i$2.at(-1);
			l$2.body.push(s$1(l$2, n));
		}
		d$1 = z(t[r$3.nextIndex], o$2);
	}
	const a$1 = C({ negate: e });
	return i$2.length === 1 ? a$1.body = i$2[0].body : (a$1.kind = "intersection", a$1.body = i$2.map((l$2) => l$2.body.length === 1 ? l$2.body[0] : l$2)), r$3.nextIndex++, a$1;
}
function ne({ kind: e, negate: r$3, value: n }, t) {
	const { normalizeUnknownPropertyNames: s$1, skipPropertyNameValidation: o$2, unicodePropertyMap: i$2 } = t;
	if (e === "property") {
		const d$1 = w(n);
		if (i.has(d$1) && !i$2?.has(d$1)) e = "posix", n = d$1;
		else return Q(n, {
			negate: r$3,
			normalizeUnknownPropertyNames: s$1,
			skipPropertyNameValidation: o$2,
			unicodePropertyMap: i$2
		});
	}
	return e === "posix" ? R(n, { negate: r$3 }) : E(e, { negate: r$3 });
}
function te(e, r$3, n) {
	const { tokens: t, capturingGroups: s$1, namedGroupsByName: o$2, skipLookbehindValidation: i$2, walk: d$1 } = r$3, a$1 = ie(e), l$2 = a$1.type === "AbsenceFunction", c = $(a$1), f$2 = c && a$1.negate;
	if (a$1.type === "CapturingGroup" && (s$1.push(a$1), a$1.name && l$1(o$2, a$1.name, []).push(a$1)), l$2 && n.isInAbsenceFunction) throw new Error("Nested absence function not supported by Oniguruma");
	let p$1 = D(t[r$3.nextIndex]);
	for (; p$1.type !== "GroupClose";) {
		if (p$1.type === "Alternator") a$1.body.push(b()), r$3.nextIndex++;
		else {
			const N = a$1.body.at(-1), u$1 = d$1(N, {
				...n,
				isInAbsenceFunction: n.isInAbsenceFunction || l$2,
				isInLookbehind: n.isInLookbehind || c,
				isInNegLookbehind: n.isInNegLookbehind || f$2
			});
			if (N.body.push(u$1), (c || n.isInLookbehind) && !i$2) {
				const v$1 = "Lookbehind includes a pattern not allowed by Oniguruma";
				if (f$2 || n.isInNegLookbehind) {
					if (M$1(u$1) || u$1.type === "CapturingGroup") throw new Error(v$1);
				} else if (M$1(u$1) || $(u$1) && u$1.negate) throw new Error(v$1);
			}
		}
		p$1 = D(t[r$3.nextIndex]);
	}
	return r$3.nextIndex++, a$1;
}
function oe({ kind: e, min: r$3, max: n }, t) {
	const s$1 = t.parent, o$2 = s$1.body.at(-1);
	if (!o$2 || !s(o$2)) throw new Error("Quantifier requires a repeatable token");
	const i$2 = _(e, r$3, n, o$2);
	return s$1.body.pop(), i$2;
}
function ae({ raw: e }, r$3) {
	const { capturingGroups: n, subroutines: t } = r$3;
	let s$1 = e.slice(3, -1);
	const o$2 = /^(?<sign>[-+]?)0*(?<num>[1-9]\d*)$/.exec(s$1);
	if (o$2) {
		const d$1 = +o$2.groups.num, a$1 = n.length;
		if (r$3.hasNumberedRef = !0, s$1 = {
			"": d$1,
			"+": a$1 + d$1,
			"-": a$1 + 1 - d$1
		}[o$2.groups.sign], s$1 < 1) throw new Error("Invalid subroutine number");
	} else s$1 === "0" && (s$1 = 0);
	const i$2 = O(s$1);
	return t.push(i$2), i$2;
}
function G(e, r$3) {
	if (e !== "repeater") throw new Error(`Unexpected absence function kind "${e}"`);
	return {
		type: "AbsenceFunction",
		kind: e,
		body: h(r$3?.body)
	};
}
function b(e) {
	return {
		type: "Alternative",
		body: V(e?.body)
	};
}
function F(e, r$3) {
	const n = {
		type: "Assertion",
		kind: e
	};
	return (e === "word_boundary" || e === "text_segment_boundary") && (n.negate = !!r$3?.negate), n;
}
function k(e, r$3) {
	const n = !!r$3?.orphan;
	return {
		type: "Backreference",
		ref: e,
		...n && { orphan: n }
	};
}
function P(e, r$3) {
	const n = {
		name: void 0,
		isSubroutined: !1,
		...r$3
	};
	if (n.name !== void 0 && !se(n.name)) throw new Error(`Group name "${n.name}" invalid in Oniguruma`);
	return {
		type: "CapturingGroup",
		number: e,
		...n.name && { name: n.name },
		...n.isSubroutined && { isSubroutined: n.isSubroutined },
		body: h(r$3?.body)
	};
}
function m(e, r$3) {
	const n = {
		useLastValid: !1,
		...r$3
	};
	if (e > 1114111) {
		const t = e.toString(16);
		if (n.useLastValid) e = 1114111;
		else throw e > 1310719 ? new Error(`Invalid code point out of range "\\x{${t}}"`) : new Error(`Invalid code point out of range in JS "\\x{${t}}"`);
	}
	return {
		type: "Character",
		value: e
	};
}
function C(e) {
	const r$3 = {
		kind: "union",
		negate: !1,
		...e
	};
	return {
		type: "CharacterClass",
		kind: r$3.kind,
		negate: r$3.negate,
		body: V(e?.body)
	};
}
function L(e, r$3) {
	if (r$3.value < e.value) throw new Error("Character class range out of order");
	return {
		type: "CharacterClassRange",
		min: e,
		max: r$3
	};
}
function E(e, r$3) {
	const n = !!r$3?.negate, t = {
		type: "CharacterSet",
		kind: e
	};
	return (e === "digit" || e === "hex" || e === "newline" || e === "space" || e === "word") && (t.negate = n), (e === "text_segment" || e === "newline" && !n) && (t.variableLength = !0), t;
}
function I(e, r$3 = {}) {
	if (e === "keep") return {
		type: "Directive",
		kind: e
	};
	if (e === "flags") return {
		type: "Directive",
		kind: e,
		flags: u(r$3.flags)
	};
	throw new Error(`Unexpected directive kind "${e}"`);
}
function T(e) {
	return {
		type: "Flags",
		...e
	};
}
function A(e) {
	const r$3 = e?.atomic, n = e?.flags;
	if (r$3 && n) throw new Error("Atomic group cannot have flags");
	return {
		type: "Group",
		...r$3 && { atomic: r$3 },
		...n && { flags: n },
		body: h(e?.body)
	};
}
function K(e) {
	const r$3 = {
		behind: !1,
		negate: !1,
		...e
	};
	return {
		type: "LookaroundAssertion",
		kind: r$3.behind ? "lookbehind" : "lookahead",
		negate: r$3.negate,
		body: h(e?.body)
	};
}
function U(e, r$3, n) {
	return {
		type: "NamedCallout",
		kind: e,
		tag: r$3,
		arguments: n
	};
}
function R(e, r$3) {
	const n = !!r$3?.negate;
	if (!i.has(e)) throw new Error(`Invalid POSIX class "${e}"`);
	return {
		type: "CharacterSet",
		kind: "posix",
		value: e,
		negate: n
	};
}
function _(e, r$3, n, t) {
	if (r$3 > n) throw new Error("Invalid reversed quantifier range");
	return {
		type: "Quantifier",
		kind: e,
		min: r$3,
		max: n,
		body: t
	};
}
function B(e, r$3) {
	return {
		type: "Regex",
		body: h(r$3?.body),
		flags: e
	};
}
function O(e) {
	return {
		type: "Subroutine",
		ref: e
	};
}
function Q(e, r$3) {
	const n = {
		negate: !1,
		normalizeUnknownPropertyNames: !1,
		skipPropertyNameValidation: !1,
		unicodePropertyMap: null,
		...r$3
	};
	let t = n.unicodePropertyMap?.get(w(e));
	if (!t) {
		if (n.normalizeUnknownPropertyNames) t = de(e);
		else if (n.unicodePropertyMap && !n.skipPropertyNameValidation) throw new Error(o$1`Invalid Unicode property "\p{${e}}"`);
	}
	return {
		type: "CharacterSet",
		kind: "property",
		value: t ?? e,
		negate: n.negate
	};
}
function ie({ flags: e, kind: r$3, name: n, negate: t, number: s$1 }) {
	switch (r$3) {
		case "absence_repeater": return G("repeater");
		case "atomic": return A({ atomic: !0 });
		case "capturing": return P(s$1, { name: n });
		case "group": return A({ flags: e });
		case "lookahead":
		case "lookbehind": return K({
			behind: r$3 === "lookbehind",
			negate: t
		});
		default: throw new Error(`Unexpected group kind "${r$3}"`);
	}
}
function h(e) {
	if (e === void 0) e = [b()];
	else if (!Array.isArray(e) || !e.length || !e.every((r$3) => r$3.type === "Alternative")) throw new Error("Invalid body; expected array of one or more Alternative nodes");
	return e;
}
function V(e) {
	if (e === void 0) e = [];
	else if (!Array.isArray(e) || !e.every((r$3) => !!r$3.type)) throw new Error("Invalid body; expected array of nodes");
	return e;
}
function M$1(e) {
	return e.type === "LookaroundAssertion" && e.kind === "lookahead";
}
function $(e) {
	return e.type === "LookaroundAssertion" && e.kind === "lookbehind";
}
function se(e) {
	return /^[\p{Alpha}\p{Pc}][^)]*$/u.test(e);
}
function de(e) {
	return e.trim().replace(/[- _]+/g, "_").replace(/[A-Z][a-z]+(?=[A-Z])/g, "$&_").replace(/[A-Za-z]+/g, (r$3) => r$3[0].toUpperCase() + r$3.slice(1).toLowerCase());
}
function w(e) {
	return e.replace(/[- _]+/g, "").toLowerCase();
}
function z(e, r$3) {
	return u(e, `${r$3?.type === "Character" && r$3.value === 93 ? "Empty" : "Unclosed"} character class`);
}
function D(e) {
	return u(e, "Unclosed group");
}

//#endregion
//#region ../../node_modules/.bun/oniguruma-parser@0.12.1/node_modules/oniguruma-parser/dist/traverser/traverse.js
function S(a$1, v$1, N = null) {
	function u$1(e, s$1) {
		for (let t = 0; t < e.length; t++) {
			const r$3 = n(e[t], s$1, t, e);
			t = Math.max(-1, t + r$3);
		}
	}
	function n(e, s$1 = null, t = null, r$3 = null) {
		let i$2 = 0, c = !1;
		const d$1 = {
			node: e,
			parent: s$1,
			key: t,
			container: r$3,
			root: a$1,
			remove() {
				f(r$3).splice(Math.max(0, l(t) + i$2), 1), i$2--, c = !0;
			},
			removeAllNextSiblings() {
				return f(r$3).splice(l(t) + 1);
			},
			removeAllPrevSiblings() {
				const o$2 = l(t) + i$2;
				return i$2 -= o$2, f(r$3).splice(0, Math.max(0, o$2));
			},
			replaceWith(o$2, y$2 = {}) {
				const b$2 = !!y$2.traverse;
				r$3 ? r$3[Math.max(0, l(t) + i$2)] = o$2 : u(s$1, "Can't replace root node")[t] = o$2, b$2 && n(o$2, s$1, t, r$3), c = !0;
			},
			replaceWithMultiple(o$2, y$2 = {}) {
				const b$2 = !!y$2.traverse;
				if (f(r$3).splice(Math.max(0, l(t) + i$2), 1, ...o$2), i$2 += o$2.length - 1, b$2) {
					let g = 0;
					for (let x$1 = 0; x$1 < o$2.length; x$1++) g += n(o$2[x$1], s$1, l(t) + x$1 + g, r$3);
				}
				c = !0;
			},
			skip() {
				c = !0;
			}
		}, { type: m$2 } = e, h$1 = v$1["*"], p$1 = v$1[m$2], R$2 = typeof h$1 == "function" ? h$1 : h$1?.enter, P$2 = typeof p$1 == "function" ? p$1 : p$1?.enter;
		if (R$2?.(d$1, N), P$2?.(d$1, N), !c) switch (m$2) {
			case "AbsenceFunction":
			case "CapturingGroup":
			case "Group":
				u$1(e.body, e);
				break;
			case "Alternative":
			case "CharacterClass":
				u$1(e.body, e);
				break;
			case "Assertion":
			case "Backreference":
			case "Character":
			case "CharacterSet":
			case "Directive":
			case "Flags":
			case "NamedCallout":
			case "Subroutine": break;
			case "CharacterClassRange":
				n(e.min, e, "min"), n(e.max, e, "max");
				break;
			case "LookaroundAssertion":
				u$1(e.body, e);
				break;
			case "Quantifier":
				n(e.body, e, "body");
				break;
			case "Regex":
				u$1(e.body, e), n(e.flags, e, "flags");
				break;
			default: throw new Error(`Unexpected node type "${m$2}"`);
		}
		return p$1?.exit?.(d$1, N), h$1?.exit?.(d$1, N), i$2;
	}
	return n(a$1), a$1;
}
function f(a$1) {
	if (!Array.isArray(a$1)) throw new Error("Container expected");
	return a$1;
}
function l(a$1) {
	if (typeof a$1 != "number") throw new Error("Numeric key expected");
	return a$1;
}

//#endregion
//#region ../../node_modules/.bun/regex@6.0.1/node_modules/regex/src/utils-internals.js
const noncapturingDelim = String.raw`\(\?(?:[:=!>A-Za-z\-]|<[=!]|\(DEFINE\))`;
/**
Updates the array in place by incrementing each value greater than or equal to the threshold.
@param {Array<number>} arr
@param {number} threshold
*/
function incrementIfAtLeast$1(arr, threshold) {
	for (let i$2 = 0; i$2 < arr.length; i$2++) {
		if (arr[i$2] >= threshold) {
			arr[i$2]++;
		}
	}
}
/**
@param {string} str
@param {number} pos
@param {string} oldValue
@param {string} newValue
@returns {string}
*/
function spliceStr(str, pos, oldValue, newValue) {
	return str.slice(0, pos) + newValue + str.slice(pos + oldValue.length);
}

//#endregion
//#region ../../node_modules/.bun/regex-utilities@2.3.0/node_modules/regex-utilities/src/index.js
const Context = Object.freeze({
	DEFAULT: "DEFAULT",
	CHAR_CLASS: "CHAR_CLASS"
});
/**
Replaces all unescaped instances of a regex pattern in the given context, using a replacement
string or callback.

Doesn't skip over complete multicharacter tokens (only `\` plus its folowing char) so must be used
with knowledge of what's safe to do given regex syntax. Assumes UnicodeSets-mode syntax.
@param {string} expression Search target
@param {string} needle Search as a regex pattern, with flags `su` applied
@param {string | (match: RegExpExecArray, details: {
context: 'DEFAULT' | 'CHAR_CLASS';
negated: boolean;
}) => string} replacement
@param {'DEFAULT' | 'CHAR_CLASS'} [context] All contexts if not specified
@returns {string} Updated expression
@example
const str = '.\\.\\\\.[[\\.].].';
replaceUnescaped(str, '\\.', '@');
// → '@\\.\\\\@[[\\.]@]@'
replaceUnescaped(str, '\\.', '@', Context.DEFAULT);
// → '@\\.\\\\@[[\\.].]@'
replaceUnescaped(str, '\\.', '@', Context.CHAR_CLASS);
// → '.\\.\\\\.[[\\.]@].'
*/
function replaceUnescaped(expression, needle, replacement, context) {
	const re$2 = new RegExp(String.raw`${needle}|(?<$skip>\[\^?|\\?.)`, "gsu");
	const negated = [false];
	let numCharClassesOpen = 0;
	let result = "";
	for (const match of expression.matchAll(re$2)) {
		const { 0: m$2, groups: { $skip } } = match;
		if (!$skip && (!context || context === Context.DEFAULT === !numCharClassesOpen)) {
			if (replacement instanceof Function) {
				result += replacement(match, {
					context: numCharClassesOpen ? Context.CHAR_CLASS : Context.DEFAULT,
					negated: negated[negated.length - 1]
				});
			} else {
				result += replacement;
			}
			continue;
		}
		if (m$2[0] === "[") {
			numCharClassesOpen++;
			negated.push(m$2[1] === "^");
		} else if (m$2 === "]" && numCharClassesOpen) {
			numCharClassesOpen--;
			negated.pop();
		}
		result += m$2;
	}
	return result;
}
/**
Runs a callback for each unescaped instance of a regex pattern in the given context.

Doesn't skip over complete multicharacter tokens (only `\` plus its folowing char) so must be used
with knowledge of what's safe to do given regex syntax. Assumes UnicodeSets-mode syntax.
@param {string} expression Search target
@param {string} needle Search as a regex pattern, with flags `su` applied
@param {(match: RegExpExecArray, details: {
context: 'DEFAULT' | 'CHAR_CLASS';
negated: boolean;
}) => void} callback
@param {'DEFAULT' | 'CHAR_CLASS'} [context] All contexts if not specified
*/
function forEachUnescaped(expression, needle, callback, context) {
	replaceUnescaped(expression, needle, callback, context);
}
/**
Returns a match object for the first unescaped instance of a regex pattern in the given context, or
`null`.

Doesn't skip over complete multicharacter tokens (only `\` plus its folowing char) so must be used
with knowledge of what's safe to do given regex syntax. Assumes UnicodeSets-mode syntax.
@param {string} expression Search target
@param {string} needle Search as a regex pattern, with flags `su` applied
@param {number} [pos] Offset to start the search
@param {'DEFAULT' | 'CHAR_CLASS'} [context] All contexts if not specified
@returns {RegExpExecArray | null}
*/
function execUnescaped(expression, needle, pos = 0, context) {
	if (!new RegExp(needle, "su").test(expression)) {
		return null;
	}
	const re$2 = new RegExp(`${needle}|(?<$skip>\\\\?.)`, "gsu");
	re$2.lastIndex = pos;
	let numCharClassesOpen = 0;
	let match;
	while (match = re$2.exec(expression)) {
		const { 0: m$2, groups: { $skip } } = match;
		if (!$skip && (!context || context === Context.DEFAULT === !numCharClassesOpen)) {
			return match;
		}
		if (m$2 === "[") {
			numCharClassesOpen++;
		} else if (m$2 === "]" && numCharClassesOpen) {
			numCharClassesOpen--;
		}
		if (re$2.lastIndex == match.index) {
			re$2.lastIndex++;
		}
	}
	return null;
}
/**
Checks whether an unescaped instance of a regex pattern appears in the given context.

Doesn't skip over complete multicharacter tokens (only `\` plus its folowing char) so must be used
with knowledge of what's safe to do given regex syntax. Assumes UnicodeSets-mode syntax.
@param {string} expression Search target
@param {string} needle Search as a regex pattern, with flags `su` applied
@param {'DEFAULT' | 'CHAR_CLASS'} [context] All contexts if not specified
@returns {boolean} Whether the pattern was found
*/
function hasUnescaped(expression, needle, context) {
	return !!execUnescaped(expression, needle, 0, context);
}
/**
Extracts the full contents of a group (subpattern) from the given expression, accounting for
escaped characters, nested groups, and character classes. The group is identified by the position
where its contents start (the string index just after the group's opening delimiter). Returns the
rest of the string if the group is unclosed.

Assumes UnicodeSets-mode syntax.
@param {string} expression Search target
@param {number} contentsStartPos
@returns {string}
*/
function getGroupContents(expression, contentsStartPos) {
	const token$1 = /\\?./gsu;
	token$1.lastIndex = contentsStartPos;
	let contentsEndPos = expression.length;
	let numCharClassesOpen = 0;
	let numGroupsOpen = 1;
	let match;
	while (match = token$1.exec(expression)) {
		const [m$2] = match;
		if (m$2 === "[") {
			numCharClassesOpen++;
		} else if (!numCharClassesOpen) {
			if (m$2 === "(") {
				numGroupsOpen++;
			} else if (m$2 === ")") {
				numGroupsOpen--;
				if (!numGroupsOpen) {
					contentsEndPos = match.index;
					break;
				}
			}
		} else if (m$2 === "]") {
			numCharClassesOpen--;
		}
	}
	return expression.slice(contentsStartPos, contentsEndPos);
}

//#endregion
//#region ../../node_modules/.bun/regex@6.0.1/node_modules/regex/src/atomic.js
const atomicPluginToken = new RegExp(String.raw`(?<noncapturingStart>${noncapturingDelim})|(?<capturingStart>\((?:\?<[^>]+>)?)|\\?.`, "gsu");
/**
Apply transformations for atomic groups: `(?>…)`.
@param {string} expression
@param {import('./regex.js').PluginData} [data]
@returns {Required<import('./regex.js').PluginResult>}
*/
function atomic(expression, data) {
	const hiddenCaptures = data?.hiddenCaptures ?? [];
	let captureTransfers = data?.captureTransfers ?? new Map();
	if (!/\(\?>/.test(expression)) {
		return {
			pattern: expression,
			captureTransfers,
			hiddenCaptures
		};
	}
	const aGDelim = "(?>";
	const emulatedAGDelim = "(?:(?=(";
	const captureNumMap = [0];
	const addedHiddenCaptures = [];
	let numCapturesBeforeAG = 0;
	let numAGs = 0;
	let aGPos = NaN;
	let hasProcessedAG;
	do {
		hasProcessedAG = false;
		let numCharClassesOpen = 0;
		let numGroupsOpenInAG = 0;
		let inAG = false;
		let match;
		atomicPluginToken.lastIndex = Number.isNaN(aGPos) ? 0 : aGPos + emulatedAGDelim.length;
		while (match = atomicPluginToken.exec(expression)) {
			const { 0: m$2, index, groups: { capturingStart, noncapturingStart } } = match;
			if (m$2 === "[") {
				numCharClassesOpen++;
			} else if (!numCharClassesOpen) {
				if (m$2 === aGDelim && !inAG) {
					aGPos = index;
					inAG = true;
				} else if (inAG && noncapturingStart) {
					numGroupsOpenInAG++;
				} else if (capturingStart) {
					if (inAG) {
						numGroupsOpenInAG++;
					} else {
						numCapturesBeforeAG++;
						captureNumMap.push(numCapturesBeforeAG + numAGs);
					}
				} else if (m$2 === ")" && inAG) {
					if (!numGroupsOpenInAG) {
						numAGs++;
						const addedCaptureNum = numCapturesBeforeAG + numAGs;
						expression = `${expression.slice(0, aGPos)}${emulatedAGDelim}${expression.slice(aGPos + aGDelim.length, index)}))<$$${addedCaptureNum}>)${expression.slice(index + 1)}`;
						hasProcessedAG = true;
						addedHiddenCaptures.push(addedCaptureNum);
						incrementIfAtLeast$1(hiddenCaptures, addedCaptureNum);
						if (captureTransfers.size) {
							const newCaptureTransfers = new Map();
							captureTransfers.forEach((from, to) => {
								newCaptureTransfers.set(to >= addedCaptureNum ? to + 1 : to, from.map((f$2) => f$2 >= addedCaptureNum ? f$2 + 1 : f$2));
							});
							captureTransfers = newCaptureTransfers;
						}
						break;
					}
					numGroupsOpenInAG--;
				}
			} else if (m$2 === "]") {
				numCharClassesOpen--;
			}
		}
	} while (hasProcessedAG);
	hiddenCaptures.push(...addedHiddenCaptures);
	expression = replaceUnescaped(expression, String.raw`\\(?<backrefNum>[1-9]\d*)|<\$\$(?<wrappedBackrefNum>\d+)>`, ({ 0: m$2, groups: { backrefNum, wrappedBackrefNum } }) => {
		if (backrefNum) {
			const bNum = +backrefNum;
			if (bNum > captureNumMap.length - 1) {
				throw new Error(`Backref "${m$2}" greater than number of captures`);
			}
			return `\\${captureNumMap[bNum]}`;
		}
		return `\\${wrappedBackrefNum}`;
	}, Context.DEFAULT);
	return {
		pattern: expression,
		captureTransfers,
		hiddenCaptures
	};
}
const baseQuantifier = String.raw`(?:[?*+]|\{\d+(?:,\d*)?\})`;
const possessivePluginToken = new RegExp(String.raw`
\\(?: \d+
  | c[A-Za-z]
  | [gk]<[^>]+>
  | [pPu]\{[^\}]+\}
  | u[A-Fa-f\d]{4}
  | x[A-Fa-f\d]{2}
  )
| \((?: \? (?: [:=!>]
  | <(?:[=!]|[^>]+>)
  | [A-Za-z\-]+:
  | \(DEFINE\)
  ))?
| (?<qBase>${baseQuantifier})(?<qMod>[?+]?)(?<invalidQ>[?*+\{]?)
| \\?.
`.replace(/\s+/g, ""), "gsu");
/**
Transform posessive quantifiers into atomic groups. The posessessive quantifiers are:
`?+`, `*+`, `++`, `{N}+`, `{N,}+`, `{N,N}+`.
This follows Java, PCRE, Perl, and Python.
Possessive quantifiers in Oniguruma and Onigmo are only: `?+`, `*+`, `++`.
@param {string} expression
@returns {import('./regex.js').PluginResult}
*/
function possessive(expression) {
	if (!new RegExp(`${baseQuantifier}\\+`).test(expression)) {
		return { pattern: expression };
	}
	const openGroupIndices = [];
	let lastGroupIndex = null;
	let lastCharClassIndex = null;
	let lastToken = "";
	let numCharClassesOpen = 0;
	let match;
	possessivePluginToken.lastIndex = 0;
	while (match = possessivePluginToken.exec(expression)) {
		const { 0: m$2, index, groups: { qBase, qMod, invalidQ } } = match;
		if (m$2 === "[") {
			if (!numCharClassesOpen) {
				lastCharClassIndex = index;
			}
			numCharClassesOpen++;
		} else if (m$2 === "]") {
			if (numCharClassesOpen) {
				numCharClassesOpen--;
			} else {
				lastCharClassIndex = null;
			}
		} else if (!numCharClassesOpen) {
			if (qMod === "+" && lastToken && !lastToken.startsWith("(")) {
				if (invalidQ) {
					throw new Error(`Invalid quantifier "${m$2}"`);
				}
				let charsAdded = -1;
				if (/^\{\d+\}$/.test(qBase)) {
					expression = spliceStr(expression, index + qBase.length, qMod, "");
				} else {
					if (lastToken === ")" || lastToken === "]") {
						const nodeIndex = lastToken === ")" ? lastGroupIndex : lastCharClassIndex;
						if (nodeIndex === null) {
							throw new Error(`Invalid unmatched "${lastToken}"`);
						}
						expression = `${expression.slice(0, nodeIndex)}(?>${expression.slice(nodeIndex, index)}${qBase})${expression.slice(index + m$2.length)}`;
					} else {
						expression = `${expression.slice(0, index - lastToken.length)}(?>${lastToken}${qBase})${expression.slice(index + m$2.length)}`;
					}
					charsAdded += 4;
				}
				possessivePluginToken.lastIndex += charsAdded;
			} else if (m$2[0] === "(") {
				openGroupIndices.push(index);
			} else if (m$2 === ")") {
				lastGroupIndex = openGroupIndices.length ? openGroupIndices.pop() : null;
			}
		}
		lastToken = m$2;
	}
	return { pattern: expression };
}

//#endregion
//#region ../../node_modules/.bun/regex@6.0.1/node_modules/regex/src/subclass.js
/**
Works the same as JavaScript's native `RegExp` constructor in all contexts, but automatically
adjusts subpattern matches and indices (with flag `d`) to account for captures added as part of
emulating extended syntax.
*/
var RegExpSubclass = class RegExpSubclass extends RegExp {
	/**
	@private
	@type {Map<number, {
	hidden: true;
	}>}
	*/
	_captureMap;
	/**
	@overload
	@param {string} expression
	@param {string} [flags]
	@param {{
	hiddenCaptures?: Array<number>;
	}} [options]
	*/
	/**
	@overload
	@param {RegExpSubclass} expression
	@param {string} [flags]
	*/
	constructor(expression, flags, options) {
		if (expression instanceof RegExp) {
			if (options) {
				throw new Error("Cannot provide options when copying a regexp");
			}
			super(expression, flags);
			if (expression instanceof RegExpSubclass) {
				this._captureMap = expression._captureMap;
			} else {
				this._captureMap = new Map();
			}
		} else {
			super(expression, flags);
			const hiddenCaptures = options?.hiddenCaptures ?? [];
			this._captureMap = createCaptureMap$1(hiddenCaptures);
		}
	}
	/**
	Called internally by all String/RegExp methods that use regexes.
	@override
	@param {string} str
	@returns {RegExpExecArray | null}
	*/
	exec(str) {
		const match = super.exec(str);
		if (!match || !this._captureMap.size) {
			return match;
		}
		const matchCopy = [...match];
		match.length = 1;
		let indicesCopy;
		if (this.hasIndices) {
			indicesCopy = [...match.indices];
			match.indices.length = 1;
		}
		for (let i$2 = 1; i$2 < matchCopy.length; i$2++) {
			if (!this._captureMap.get(i$2)?.hidden) {
				match.push(matchCopy[i$2]);
				if (this.hasIndices) {
					match.indices.push(indicesCopy[i$2]);
				}
			}
		}
		return match;
	}
};
/**
Build the capturing group map, with hidden captures marked to indicate their submatches shouldn't
appear in match results.
@param {Array<number>} hiddenCaptures
@returns {Map<number, {
hidden: true;
}>}
*/
function createCaptureMap$1(hiddenCaptures) {
	const captureMap = new Map();
	for (const num of hiddenCaptures) {
		captureMap.set(num, { hidden: true });
	}
	return captureMap;
}

//#endregion
//#region ../../node_modules/.bun/regex-recursion@6.0.2/node_modules/regex-recursion/src/index.js
const r$1 = String.raw;
const gRToken = r$1`\\g<(?<gRNameOrNum>[^>&]+)&R=(?<gRDepth>[^>]+)>`;
const recursiveToken = r$1`\(\?R=(?<rDepth>[^\)]+)\)|${gRToken}`;
const namedCaptureDelim = r$1`\(\?<(?![=!])(?<captureName>[^>]+)>`;
const captureDelim = r$1`${namedCaptureDelim}|(?<unnamed>\()(?!\?)`;
const token = new RegExp(r$1`${namedCaptureDelim}|${recursiveToken}|\(\?|\\?.`, "gsu");
const overlappingRecursionMsg = "Cannot use multiple overlapping recursions";
/**
@param {string} pattern
@param {{
flags?: string;
captureTransfers?: Map<number, Array<number>>;
hiddenCaptures?: Array<number>;
mode?: 'plugin' | 'external';
}} [data]
@returns {{
pattern: string;
captureTransfers: Map<number, Array<number>>;
hiddenCaptures: Array<number>;
}}
*/
function recursion(pattern, data) {
	const { hiddenCaptures, mode } = {
		hiddenCaptures: [],
		mode: "plugin",
		...data
	};
	let captureTransfers = data?.captureTransfers ?? new Map();
	if (!new RegExp(recursiveToken, "su").test(pattern)) {
		return {
			pattern,
			captureTransfers,
			hiddenCaptures
		};
	}
	if (mode === "plugin" && hasUnescaped(pattern, r$1`\(\?\(DEFINE\)`, Context.DEFAULT)) {
		throw new Error("DEFINE groups cannot be used with recursion");
	}
	const addedHiddenCaptures = [];
	const hasNumberedBackref = hasUnescaped(pattern, r$1`\\[1-9]`, Context.DEFAULT);
	const groupContentsStartPos = new Map();
	const openGroups = [];
	let hasRecursed = false;
	let numCharClassesOpen = 0;
	let numCapturesPassed = 0;
	let match;
	token.lastIndex = 0;
	while (match = token.exec(pattern)) {
		const { 0: m$2, groups: { captureName, rDepth, gRNameOrNum, gRDepth } } = match;
		if (m$2 === "[") {
			numCharClassesOpen++;
		} else if (!numCharClassesOpen) {
			if (rDepth) {
				assertMaxInBounds(rDepth);
				if (hasRecursed) {
					throw new Error(overlappingRecursionMsg);
				}
				if (hasNumberedBackref) {
					throw new Error(`${mode === "external" ? "Backrefs" : "Numbered backrefs"} cannot be used with global recursion`);
				}
				const left = pattern.slice(0, match.index);
				const right = pattern.slice(token.lastIndex);
				if (hasUnescaped(right, recursiveToken, Context.DEFAULT)) {
					throw new Error(overlappingRecursionMsg);
				}
				const reps = +rDepth - 1;
				pattern = makeRecursive(left, right, reps, false, hiddenCaptures, addedHiddenCaptures, numCapturesPassed);
				captureTransfers = mapCaptureTransfers(captureTransfers, left, reps, addedHiddenCaptures.length, 0, numCapturesPassed);
				break;
			} else if (gRNameOrNum) {
				assertMaxInBounds(gRDepth);
				let isWithinReffedGroup = false;
				for (const g of openGroups) {
					if (g.name === gRNameOrNum || g.num === +gRNameOrNum) {
						isWithinReffedGroup = true;
						if (g.hasRecursedWithin) {
							throw new Error(overlappingRecursionMsg);
						}
						break;
					}
				}
				if (!isWithinReffedGroup) {
					throw new Error(r$1`Recursive \g cannot be used outside the referenced group "${mode === "external" ? gRNameOrNum : r$1`\g<${gRNameOrNum}&R=${gRDepth}>`}"`);
				}
				const startPos = groupContentsStartPos.get(gRNameOrNum);
				const groupContents = getGroupContents(pattern, startPos);
				if (hasNumberedBackref && hasUnescaped(groupContents, r$1`${namedCaptureDelim}|\((?!\?)`, Context.DEFAULT)) {
					throw new Error(`${mode === "external" ? "Backrefs" : "Numbered backrefs"} cannot be used with recursion of capturing groups`);
				}
				const groupContentsLeft = pattern.slice(startPos, match.index);
				const groupContentsRight = groupContents.slice(groupContentsLeft.length + m$2.length);
				const numAddedHiddenCapturesPreExpansion = addedHiddenCaptures.length;
				const reps = +gRDepth - 1;
				const expansion = makeRecursive(groupContentsLeft, groupContentsRight, reps, true, hiddenCaptures, addedHiddenCaptures, numCapturesPassed);
				captureTransfers = mapCaptureTransfers(captureTransfers, groupContentsLeft, reps, addedHiddenCaptures.length - numAddedHiddenCapturesPreExpansion, numAddedHiddenCapturesPreExpansion, numCapturesPassed);
				const pre = pattern.slice(0, startPos);
				const post = pattern.slice(startPos + groupContents.length);
				pattern = `${pre}${expansion}${post}`;
				token.lastIndex += expansion.length - m$2.length - groupContentsLeft.length - groupContentsRight.length;
				openGroups.forEach((g) => g.hasRecursedWithin = true);
				hasRecursed = true;
			} else if (captureName) {
				numCapturesPassed++;
				groupContentsStartPos.set(String(numCapturesPassed), token.lastIndex);
				groupContentsStartPos.set(captureName, token.lastIndex);
				openGroups.push({
					num: numCapturesPassed,
					name: captureName
				});
			} else if (m$2[0] === "(") {
				const isUnnamedCapture = m$2 === "(";
				if (isUnnamedCapture) {
					numCapturesPassed++;
					groupContentsStartPos.set(String(numCapturesPassed), token.lastIndex);
				}
				openGroups.push(isUnnamedCapture ? { num: numCapturesPassed } : {});
			} else if (m$2 === ")") {
				openGroups.pop();
			}
		} else if (m$2 === "]") {
			numCharClassesOpen--;
		}
	}
	hiddenCaptures.push(...addedHiddenCaptures);
	return {
		pattern,
		captureTransfers,
		hiddenCaptures
	};
}
/**
@param {string} max
*/
function assertMaxInBounds(max) {
	const errMsg = `Max depth must be integer between 2 and 100; used ${max}`;
	if (!/^[1-9]\d*$/.test(max)) {
		throw new Error(errMsg);
	}
	max = +max;
	if (max < 2 || max > 100) {
		throw new Error(errMsg);
	}
}
/**
@param {string} left
@param {string} right
@param {number} reps
@param {boolean} isSubpattern
@param {Array<number>} hiddenCaptures
@param {Array<number>} addedHiddenCaptures
@param {number} numCapturesPassed
@returns {string}
*/
function makeRecursive(left, right, reps, isSubpattern, hiddenCaptures, addedHiddenCaptures, numCapturesPassed) {
	const namesInRecursed = new Set();
	if (isSubpattern) {
		forEachUnescaped(left + right, namedCaptureDelim, ({ groups: { captureName } }) => {
			namesInRecursed.add(captureName);
		}, Context.DEFAULT);
	}
	const rest = [
		reps,
		isSubpattern ? namesInRecursed : null,
		hiddenCaptures,
		addedHiddenCaptures,
		numCapturesPassed
	];
	return `${left}${repeatWithDepth(`(?:${left}`, "forward", ...rest)}(?:)${repeatWithDepth(`${right})`, "backward", ...rest)}${right}`;
}
/**
@param {string} pattern
@param {'forward' | 'backward'} direction
@param {number} reps
@param {Set<string> | null} namesInRecursed
@param {Array<number>} hiddenCaptures
@param {Array<number>} addedHiddenCaptures
@param {number} numCapturesPassed
@returns {string}
*/
function repeatWithDepth(pattern, direction, reps, namesInRecursed, hiddenCaptures, addedHiddenCaptures, numCapturesPassed) {
	const startNum = 2;
	const getDepthNum = (i$2) => direction === "forward" ? i$2 + startNum : reps - i$2 + startNum - 1;
	let result = "";
	for (let i$2 = 0; i$2 < reps; i$2++) {
		const depthNum = getDepthNum(i$2);
		result += replaceUnescaped(pattern, r$1`${captureDelim}|\\k<(?<backref>[^>]+)>`, ({ 0: m$2, groups: { captureName, unnamed, backref } }) => {
			if (backref && namesInRecursed && !namesInRecursed.has(backref)) {
				return m$2;
			}
			const suffix = `_$${depthNum}`;
			if (unnamed || captureName) {
				const addedCaptureNum = numCapturesPassed + addedHiddenCaptures.length + 1;
				addedHiddenCaptures.push(addedCaptureNum);
				incrementIfAtLeast(hiddenCaptures, addedCaptureNum);
				return unnamed ? m$2 : `(?<${captureName}${suffix}>`;
			}
			return r$1`\k<${backref}${suffix}>`;
		}, Context.DEFAULT);
	}
	return result;
}
/**
Updates the array in place by incrementing each value greater than or equal to the threshold.
@param {Array<number>} arr
@param {number} threshold
*/
function incrementIfAtLeast(arr, threshold) {
	for (let i$2 = 0; i$2 < arr.length; i$2++) {
		if (arr[i$2] >= threshold) {
			arr[i$2]++;
		}
	}
}
/**
@param {Map<number, Array<number>>} captureTransfers
@param {string} left
@param {number} reps
@param {number} numCapturesAddedInExpansion
@param {number} numAddedHiddenCapturesPreExpansion
@param {number} numCapturesPassed
@returns {Map<number, Array<number>>}
*/
function mapCaptureTransfers(captureTransfers, left, reps, numCapturesAddedInExpansion, numAddedHiddenCapturesPreExpansion, numCapturesPassed) {
	if (captureTransfers.size && numCapturesAddedInExpansion) {
		let numCapturesInLeft = 0;
		forEachUnescaped(left, captureDelim, () => numCapturesInLeft++, Context.DEFAULT);
		const recursionDelimCaptureNum = numCapturesPassed - numCapturesInLeft + numAddedHiddenCapturesPreExpansion;
		const newCaptureTransfers = new Map();
		captureTransfers.forEach((from, to) => {
			const numCapturesInRight = (numCapturesAddedInExpansion - numCapturesInLeft * reps) / reps;
			const numCapturesAddedInLeft = numCapturesInLeft * reps;
			const newTo = to > recursionDelimCaptureNum + numCapturesInLeft ? to + numCapturesAddedInExpansion : to;
			const newFrom = [];
			for (const f$2 of from) {
				if (f$2 <= recursionDelimCaptureNum) {
					newFrom.push(f$2);
				} else if (f$2 > recursionDelimCaptureNum + numCapturesInLeft + numCapturesInRight) {
					newFrom.push(f$2 + numCapturesAddedInExpansion);
				} else if (f$2 <= recursionDelimCaptureNum + numCapturesInLeft) {
					for (let i$2 = 0; i$2 <= reps; i$2++) {
						newFrom.push(f$2 + numCapturesInLeft * i$2);
					}
				} else {
					for (let i$2 = 0; i$2 <= reps; i$2++) {
						newFrom.push(f$2 + numCapturesAddedInLeft + numCapturesInRight * i$2);
					}
				}
			}
			newCaptureTransfers.set(newTo, newFrom);
		});
		return newCaptureTransfers;
	}
	return captureTransfers;
}

//#endregion
//#region ../../node_modules/.bun/oniguruma-to-es@4.3.4/node_modules/oniguruma-to-es/dist/esm/index.js
var cp = String.fromCodePoint;
var r = String.raw;
var envFlags = {
	flagGroups: (() => {
		try {
			new RegExp("(?i:)");
		} catch {
			return false;
		}
		return true;
	})(),
	unicodeSets: (() => {
		try {
			new RegExp("[[]]", "v");
		} catch {
			return false;
		}
		return true;
	})()
};
envFlags.bugFlagVLiteralHyphenIsRange = envFlags.unicodeSets ? (() => {
	try {
		new RegExp(r`[\d\-a]`, "v");
	} catch {
		return true;
	}
	return false;
})() : false;
envFlags.bugNestedClassIgnoresNegation = envFlags.unicodeSets && new RegExp("[[^a]]", "v").test("a");
function getNewCurrentFlags(current, { enable, disable }) {
	return {
		dotAll: !disable?.dotAll && !!(enable?.dotAll || current.dotAll),
		ignoreCase: !disable?.ignoreCase && !!(enable?.ignoreCase || current.ignoreCase)
	};
}
function getOrInsert(map, key$1, defaultValue) {
	if (!map.has(key$1)) {
		map.set(key$1, defaultValue);
	}
	return map.get(key$1);
}
function isMinTarget(target, min) {
	return EsVersion[target] >= EsVersion[min];
}
function throwIfNullish(value, msg) {
	if (value == null) {
		throw new Error(msg ?? "Value expected");
	}
	return value;
}
var EsVersion = {
	ES2025: 2025,
	ES2024: 2024,
	ES2018: 2018
};
var Target = (
/** @type {const} */
{
	auto: "auto",
	ES2025: "ES2025",
	ES2024: "ES2024",
	ES2018: "ES2018"
});
function getOptions(options = {}) {
	if ({}.toString.call(options) !== "[object Object]") {
		throw new Error("Unexpected options");
	}
	if (options.target !== void 0 && !Target[options.target]) {
		throw new Error(`Unexpected target "${options.target}"`);
	}
	const opts = {
		accuracy: "default",
		avoidSubclass: false,
		flags: "",
		global: false,
		hasIndices: false,
		lazyCompileLength: Infinity,
		target: "auto",
		verbose: false,
		...options,
		rules: {
			allowOrphanBackrefs: false,
			asciiWordBoundaries: false,
			captureGroup: false,
			recursionLimit: 20,
			singleline: false,
			...options.rules
		}
	};
	if (opts.target === "auto") {
		opts.target = envFlags.flagGroups ? "ES2025" : envFlags.unicodeSets ? "ES2024" : "ES2018";
	}
	return opts;
}
var asciiSpaceChar = "[	-\r ]";
var CharsWithoutIgnoreCaseExpansion = /* @__PURE__ */ new Set([cp(304), cp(305)]);
var defaultWordChar = r`[\p{L}\p{M}\p{N}\p{Pc}]`;
function getIgnoreCaseMatchChars(char) {
	if (CharsWithoutIgnoreCaseExpansion.has(char)) {
		return [char];
	}
	const set = /* @__PURE__ */ new Set();
	const lower = char.toLowerCase();
	const upper = lower.toUpperCase();
	const title = LowerToTitleCaseMap.get(lower);
	const altLower = LowerToAlternativeLowerCaseMap.get(lower);
	const altUpper = LowerToAlternativeUpperCaseMap.get(lower);
	if ([...upper].length === 1) {
		set.add(upper);
	}
	altUpper && set.add(altUpper);
	title && set.add(title);
	set.add(lower);
	altLower && set.add(altLower);
	return [...set];
}
var JsUnicodePropertyMap = /* @__PURE__ */ new Map(`C Other
Cc Control cntrl
Cf Format
Cn Unassigned
Co Private_Use
Cs Surrogate
L Letter
LC Cased_Letter
Ll Lowercase_Letter
Lm Modifier_Letter
Lo Other_Letter
Lt Titlecase_Letter
Lu Uppercase_Letter
M Mark Combining_Mark
Mc Spacing_Mark
Me Enclosing_Mark
Mn Nonspacing_Mark
N Number
Nd Decimal_Number digit
Nl Letter_Number
No Other_Number
P Punctuation punct
Pc Connector_Punctuation
Pd Dash_Punctuation
Pe Close_Punctuation
Pf Final_Punctuation
Pi Initial_Punctuation
Po Other_Punctuation
Ps Open_Punctuation
S Symbol
Sc Currency_Symbol
Sk Modifier_Symbol
Sm Math_Symbol
So Other_Symbol
Z Separator
Zl Line_Separator
Zp Paragraph_Separator
Zs Space_Separator
ASCII
ASCII_Hex_Digit AHex
Alphabetic Alpha
Any
Assigned
Bidi_Control Bidi_C
Bidi_Mirrored Bidi_M
Case_Ignorable CI
Cased
Changes_When_Casefolded CWCF
Changes_When_Casemapped CWCM
Changes_When_Lowercased CWL
Changes_When_NFKC_Casefolded CWKCF
Changes_When_Titlecased CWT
Changes_When_Uppercased CWU
Dash
Default_Ignorable_Code_Point DI
Deprecated Dep
Diacritic Dia
Emoji
Emoji_Component EComp
Emoji_Modifier EMod
Emoji_Modifier_Base EBase
Emoji_Presentation EPres
Extended_Pictographic ExtPict
Extender Ext
Grapheme_Base Gr_Base
Grapheme_Extend Gr_Ext
Hex_Digit Hex
IDS_Binary_Operator IDSB
IDS_Trinary_Operator IDST
ID_Continue IDC
ID_Start IDS
Ideographic Ideo
Join_Control Join_C
Logical_Order_Exception LOE
Lowercase Lower
Math
Noncharacter_Code_Point NChar
Pattern_Syntax Pat_Syn
Pattern_White_Space Pat_WS
Quotation_Mark QMark
Radical
Regional_Indicator RI
Sentence_Terminal STerm
Soft_Dotted SD
Terminal_Punctuation Term
Unified_Ideograph UIdeo
Uppercase Upper
Variation_Selector VS
White_Space space
XID_Continue XIDC
XID_Start XIDS`.split(/\s/).map((p$1) => [w(p$1), p$1]));
var LowerToAlternativeLowerCaseMap = /* @__PURE__ */ new Map([["s", cp(383)], [cp(383), "s"]]);
var LowerToAlternativeUpperCaseMap = /* @__PURE__ */ new Map([
	[cp(223), cp(7838)],
	[cp(107), cp(8490)],
	[cp(229), cp(8491)],
	[cp(969), cp(8486)]
]);
var LowerToTitleCaseMap = new Map([
	titleEntry(453),
	titleEntry(456),
	titleEntry(459),
	titleEntry(498),
	...titleRange(8072, 8079),
	...titleRange(8088, 8095),
	...titleRange(8104, 8111),
	titleEntry(8124),
	titleEntry(8140),
	titleEntry(8188)
]);
var PosixClassMap = /* @__PURE__ */ new Map([
	["alnum", r`[\p{Alpha}\p{Nd}]`],
	["alpha", r`\p{Alpha}`],
	["ascii", r`\p{ASCII}`],
	["blank", r`[\p{Zs}\t]`],
	["cntrl", r`\p{Cc}`],
	["digit", r`\p{Nd}`],
	["graph", r`[\P{space}&&\P{Cc}&&\P{Cn}&&\P{Cs}]`],
	["lower", r`\p{Lower}`],
	["print", r`[[\P{space}&&\P{Cc}&&\P{Cn}&&\P{Cs}]\p{Zs}]`],
	["punct", r`[\p{P}\p{S}]`],
	["space", r`\p{space}`],
	["upper", r`\p{Upper}`],
	["word", r`[\p{Alpha}\p{M}\p{Nd}\p{Pc}]`],
	["xdigit", r`\p{AHex}`]
]);
function range(start, end) {
	const range2 = [];
	for (let i$2 = start; i$2 <= end; i$2++) {
		range2.push(i$2);
	}
	return range2;
}
function titleEntry(codePoint) {
	const char = cp(codePoint);
	return [char.toLowerCase(), char];
}
function titleRange(start, end) {
	return range(start, end).map((codePoint) => titleEntry(codePoint));
}
var UnicodePropertiesWithSpecificCase = /* @__PURE__ */ new Set([
	"Lower",
	"Lowercase",
	"Upper",
	"Uppercase",
	"Ll",
	"Lowercase_Letter",
	"Lt",
	"Titlecase_Letter",
	"Lu",
	"Uppercase_Letter"
]);
function transform(ast, options) {
	const opts = {
		accuracy: "default",
		asciiWordBoundaries: false,
		avoidSubclass: false,
		bestEffortTarget: "ES2025",
		...options
	};
	addParentProperties(ast);
	const firstPassState = {
		accuracy: opts.accuracy,
		asciiWordBoundaries: opts.asciiWordBoundaries,
		avoidSubclass: opts.avoidSubclass,
		flagDirectivesByAlt: /* @__PURE__ */ new Map(),
		jsGroupNameMap: /* @__PURE__ */ new Map(),
		minTargetEs2024: isMinTarget(opts.bestEffortTarget, "ES2024"),
		passedLookbehind: false,
		strategy: null,
		subroutineRefMap: /* @__PURE__ */ new Map(),
		supportedGNodes: /* @__PURE__ */ new Set(),
		digitIsAscii: ast.flags.digitIsAscii,
		spaceIsAscii: ast.flags.spaceIsAscii,
		wordIsAscii: ast.flags.wordIsAscii
	};
	S(ast, FirstPassVisitor, firstPassState);
	const globalFlags = {
		dotAll: ast.flags.dotAll,
		ignoreCase: ast.flags.ignoreCase
	};
	const secondPassState = {
		currentFlags: globalFlags,
		prevFlags: null,
		globalFlags,
		groupOriginByCopy: /* @__PURE__ */ new Map(),
		groupsByName: /* @__PURE__ */ new Map(),
		multiplexCapturesToLeftByRef: /* @__PURE__ */ new Map(),
		openRefs: /* @__PURE__ */ new Map(),
		reffedNodesByReferencer: /* @__PURE__ */ new Map(),
		subroutineRefMap: firstPassState.subroutineRefMap
	};
	S(ast, SecondPassVisitor, secondPassState);
	const thirdPassState = {
		groupsByName: secondPassState.groupsByName,
		highestOrphanBackref: 0,
		numCapturesToLeft: 0,
		reffedNodesByReferencer: secondPassState.reffedNodesByReferencer
	};
	S(ast, ThirdPassVisitor, thirdPassState);
	ast._originMap = secondPassState.groupOriginByCopy;
	ast._strategy = firstPassState.strategy;
	return ast;
}
var FirstPassVisitor = {
	AbsenceFunction({ node, parent, replaceWith }) {
		const { body: body$2, kind } = node;
		if (kind === "repeater") {
			const innerGroup = A();
			innerGroup.body[0].body.push(K({
				negate: true,
				body: body$2
			}), Q("Any"));
			const outerGroup = A();
			outerGroup.body[0].body.push(_("greedy", 0, Infinity, innerGroup));
			replaceWith(setParentDeep(outerGroup, parent), { traverse: true });
		} else {
			throw new Error(`Unsupported absence function "(?~|"`);
		}
	},
	Alternative: {
		enter({ node, parent, key: key$1 }, { flagDirectivesByAlt }) {
			const flagDirectives = node.body.filter((el) => el.kind === "flags");
			for (let i$2 = key$1 + 1; i$2 < parent.body.length; i$2++) {
				const forwardSiblingAlt = parent.body[i$2];
				getOrInsert(flagDirectivesByAlt, forwardSiblingAlt, []).push(...flagDirectives);
			}
		},
		exit({ node }, { flagDirectivesByAlt }) {
			if (flagDirectivesByAlt.get(node)?.length) {
				const flags = getCombinedFlagModsFromFlagNodes(flagDirectivesByAlt.get(node));
				if (flags) {
					const flagGroup = A({ flags });
					flagGroup.body[0].body = node.body;
					node.body = [setParentDeep(flagGroup, node)];
				}
			}
		}
	},
	Assertion({ node, parent, key: key$1, container, root: root$1, remove, replaceWith }, state) {
		const { kind, negate } = node;
		const { asciiWordBoundaries, avoidSubclass, supportedGNodes, wordIsAscii } = state;
		if (kind === "text_segment_boundary") {
			throw new Error(`Unsupported text segment boundary "\\${negate ? "Y" : "y"}"`);
		} else if (kind === "line_end") {
			replaceWith(setParentDeep(K({ body: [b({ body: [F("string_end")] }), b({ body: [m(10)] })] }), parent));
		} else if (kind === "line_start") {
			replaceWith(setParentDeep(parseFragment(r`(?<=\A|\n(?!\z))`, { skipLookbehindValidation: true }), parent));
		} else if (kind === "search_start") {
			if (supportedGNodes.has(node)) {
				root$1.flags.sticky = true;
				remove();
			} else {
				const prev = container[key$1 - 1];
				if (prev && isAlwaysNonZeroLength(prev)) {
					replaceWith(setParentDeep(K({ negate: true }), parent));
				} else if (avoidSubclass) {
					throw new Error(r`Uses "\G" in a way that requires a subclass`);
				} else {
					replaceWith(setParent(F("string_start"), parent));
					state.strategy = "clip_search";
				}
			}
		} else if (kind === "string_end" || kind === "string_start") {} else if (kind === "string_end_newline") {
			replaceWith(setParentDeep(parseFragment(r`(?=\n?\z)`), parent));
		} else if (kind === "word_boundary") {
			if (!wordIsAscii && !asciiWordBoundaries) {
				const b$2 = `(?:(?<=${defaultWordChar})(?!${defaultWordChar})|(?<!${defaultWordChar})(?=${defaultWordChar}))`;
				const B$2 = `(?:(?<=${defaultWordChar})(?=${defaultWordChar})|(?<!${defaultWordChar})(?!${defaultWordChar}))`;
				replaceWith(setParentDeep(parseFragment(negate ? B$2 : b$2), parent));
			}
		} else {
			throw new Error(`Unexpected assertion kind "${kind}"`);
		}
	},
	Backreference({ node }, { jsGroupNameMap }) {
		let { ref } = node;
		if (typeof ref === "string" && !isValidJsGroupName(ref)) {
			ref = getAndStoreJsGroupName(ref, jsGroupNameMap);
			node.ref = ref;
		}
	},
	CapturingGroup({ node }, { jsGroupNameMap, subroutineRefMap }) {
		let { name } = node;
		if (name && !isValidJsGroupName(name)) {
			name = getAndStoreJsGroupName(name, jsGroupNameMap);
			node.name = name;
		}
		subroutineRefMap.set(node.number, node);
		if (name) {
			subroutineRefMap.set(name, node);
		}
	},
	CharacterClassRange({ node, parent, replaceWith }) {
		if (parent.kind === "intersection") {
			const cc = C({ body: [node] });
			replaceWith(setParentDeep(cc, parent), { traverse: true });
		}
	},
	CharacterSet({ node, parent, replaceWith }, { accuracy, minTargetEs2024, digitIsAscii, spaceIsAscii, wordIsAscii }) {
		const { kind, negate, value } = node;
		if (digitIsAscii && (kind === "digit" || value === "digit")) {
			replaceWith(setParent(E("digit", { negate }), parent));
			return;
		}
		if (spaceIsAscii && (kind === "space" || value === "space")) {
			replaceWith(setParentDeep(setNegate(parseFragment(asciiSpaceChar), negate), parent));
			return;
		}
		if (wordIsAscii && (kind === "word" || value === "word")) {
			replaceWith(setParent(E("word", { negate }), parent));
			return;
		}
		if (kind === "any") {
			replaceWith(setParent(Q("Any"), parent));
		} else if (kind === "digit") {
			replaceWith(setParent(Q("Nd", { negate }), parent));
		} else if (kind === "dot") {} else if (kind === "text_segment") {
			if (accuracy === "strict") {
				throw new Error(r`Use of "\X" requires non-strict accuracy`);
			}
			const eBase = "\\p{Emoji}(?:\\p{EMod}|\\uFE0F\\u20E3?|[\\x{E0020}-\\x{E007E}]+\\x{E007F})?";
			const emoji = r`\p{RI}{2}|${eBase}(?:\u200D${eBase})*`;
			replaceWith(setParentDeep(parseFragment(r`(?>\r\n|${minTargetEs2024 ? r`\p{RGI_Emoji}` : emoji}|\P{M}\p{M}*)`, { skipPropertyNameValidation: true }), parent));
		} else if (kind === "hex") {
			replaceWith(setParent(Q("AHex", { negate }), parent));
		} else if (kind === "newline") {
			replaceWith(setParentDeep(parseFragment(negate ? "[^\n]" : "(?>\r\n?|[\n\v\f\u2028\u2029])"), parent));
		} else if (kind === "posix") {
			if (!minTargetEs2024 && (value === "graph" || value === "print")) {
				if (accuracy === "strict") {
					throw new Error(`POSIX class "${value}" requires min target ES2024 or non-strict accuracy`);
				}
				let ascii = {
					graph: "!-~",
					print: " -~"
				}[value];
				if (negate) {
					ascii = `\0-${cp(ascii.codePointAt(0) - 1)}${cp(ascii.codePointAt(2) + 1)}-\u{10FFFF}`;
				}
				replaceWith(setParentDeep(parseFragment(`[${ascii}]`), parent));
			} else {
				replaceWith(setParentDeep(setNegate(parseFragment(PosixClassMap.get(value)), negate), parent));
			}
		} else if (kind === "property") {
			if (!JsUnicodePropertyMap.has(w(value))) {
				node.key = "sc";
			}
		} else if (kind === "space") {
			replaceWith(setParent(Q("space", { negate }), parent));
		} else if (kind === "word") {
			replaceWith(setParentDeep(setNegate(parseFragment(defaultWordChar), negate), parent));
		} else {
			throw new Error(`Unexpected character set kind "${kind}"`);
		}
	},
	Directive({ node, parent, root: root$1, remove, replaceWith, removeAllPrevSiblings, removeAllNextSiblings }) {
		const { kind, flags } = node;
		if (kind === "flags") {
			if (!flags.enable && !flags.disable) {
				remove();
			} else {
				const flagGroup = A({ flags });
				flagGroup.body[0].body = removeAllNextSiblings();
				replaceWith(setParentDeep(flagGroup, parent), { traverse: true });
			}
		} else if (kind === "keep") {
			const firstAlt = root$1.body[0];
			const hasWrapperGroup = root$1.body.length === 1 && o(firstAlt, { type: "Group" }) && firstAlt.body[0].body.length === 1;
			const topLevel = hasWrapperGroup ? firstAlt.body[0] : root$1;
			if (parent.parent !== topLevel || topLevel.body.length > 1) {
				throw new Error(r`Uses "\K" in a way that's unsupported`);
			}
			const lookbehind = K({ behind: true });
			lookbehind.body[0].body = removeAllPrevSiblings();
			replaceWith(setParentDeep(lookbehind, parent));
		} else {
			throw new Error(`Unexpected directive kind "${kind}"`);
		}
	},
	Flags({ node, parent }) {
		if (node.posixIsAscii) {
			throw new Error("Unsupported flag \"P\"");
		}
		if (node.textSegmentMode === "word") {
			throw new Error("Unsupported flag \"y{w}\"");
		}
		[
			"digitIsAscii",
			"extended",
			"posixIsAscii",
			"spaceIsAscii",
			"wordIsAscii",
			"textSegmentMode"
		].forEach((f$2) => delete node[f$2]);
		Object.assign(node, {
			global: false,
			hasIndices: false,
			multiline: false,
			sticky: node.sticky ?? false
		});
		parent.options = {
			disable: {
				x: true,
				n: true
			},
			force: { v: true }
		};
	},
	Group({ node }) {
		if (!node.flags) {
			return;
		}
		const { enable, disable } = node.flags;
		enable?.extended && delete enable.extended;
		disable?.extended && delete disable.extended;
		enable?.dotAll && disable?.dotAll && delete enable.dotAll;
		enable?.ignoreCase && disable?.ignoreCase && delete enable.ignoreCase;
		enable && !Object.keys(enable).length && delete node.flags.enable;
		disable && !Object.keys(disable).length && delete node.flags.disable;
		!node.flags.enable && !node.flags.disable && delete node.flags;
	},
	LookaroundAssertion({ node }, state) {
		const { kind } = node;
		if (kind === "lookbehind") {
			state.passedLookbehind = true;
		}
	},
	NamedCallout({ node, parent, replaceWith }) {
		const { kind } = node;
		if (kind === "fail") {
			replaceWith(setParentDeep(K({ negate: true }), parent));
		} else {
			throw new Error(`Unsupported named callout "(*${kind.toUpperCase()}"`);
		}
	},
	Quantifier({ node }) {
		if (node.body.type === "Quantifier") {
			const group = A();
			group.body[0].body.push(node.body);
			node.body = setParentDeep(group, node);
		}
	},
	Regex: {
		enter({ node }, { supportedGNodes }) {
			const leadingGs = [];
			let hasAltWithLeadG = false;
			let hasAltWithoutLeadG = false;
			for (const alt of node.body) {
				if (alt.body.length === 1 && alt.body[0].kind === "search_start") {
					alt.body.pop();
				} else {
					const leadingG = getLeadingG(alt.body);
					if (leadingG) {
						hasAltWithLeadG = true;
						Array.isArray(leadingG) ? leadingGs.push(...leadingG) : leadingGs.push(leadingG);
					} else {
						hasAltWithoutLeadG = true;
					}
				}
			}
			if (hasAltWithLeadG && !hasAltWithoutLeadG) {
				leadingGs.forEach((g) => supportedGNodes.add(g));
			}
		},
		exit(_$2, { accuracy, passedLookbehind, strategy }) {
			if (accuracy === "strict" && passedLookbehind && strategy) {
				throw new Error(r`Uses "\G" in a way that requires non-strict accuracy`);
			}
		}
	},
	Subroutine({ node }, { jsGroupNameMap }) {
		let { ref } = node;
		if (typeof ref === "string" && !isValidJsGroupName(ref)) {
			ref = getAndStoreJsGroupName(ref, jsGroupNameMap);
			node.ref = ref;
		}
	}
};
var SecondPassVisitor = {
	Backreference({ node }, { multiplexCapturesToLeftByRef, reffedNodesByReferencer }) {
		const { orphan, ref } = node;
		if (!orphan) {
			reffedNodesByReferencer.set(node, [...multiplexCapturesToLeftByRef.get(ref).map(({ node: node2 }) => node2)]);
		}
	},
	CapturingGroup: {
		enter({ node, parent, replaceWith, skip }, { groupOriginByCopy, groupsByName, multiplexCapturesToLeftByRef, openRefs, reffedNodesByReferencer }) {
			const origin = groupOriginByCopy.get(node);
			if (origin && openRefs.has(node.number)) {
				const recursion2 = setParent(createRecursion(node.number), parent);
				reffedNodesByReferencer.set(recursion2, openRefs.get(node.number));
				replaceWith(recursion2);
				return;
			}
			openRefs.set(node.number, node);
			multiplexCapturesToLeftByRef.set(node.number, []);
			if (node.name) {
				getOrInsert(multiplexCapturesToLeftByRef, node.name, []);
			}
			const multiplexNodes = multiplexCapturesToLeftByRef.get(node.name ?? node.number);
			for (let i$2 = 0; i$2 < multiplexNodes.length; i$2++) {
				const multiplex = multiplexNodes[i$2];
				if (origin === multiplex.node || origin && origin === multiplex.origin || node === multiplex.origin) {
					multiplexNodes.splice(i$2, 1);
					break;
				}
			}
			multiplexCapturesToLeftByRef.get(node.number).push({
				node,
				origin
			});
			if (node.name) {
				multiplexCapturesToLeftByRef.get(node.name).push({
					node,
					origin
				});
			}
			if (node.name) {
				const groupsWithSameName = getOrInsert(groupsByName, node.name, /* @__PURE__ */ new Map());
				let hasDuplicateNameToRemove = false;
				if (origin) {
					hasDuplicateNameToRemove = true;
				} else {
					for (const groupInfo of groupsWithSameName.values()) {
						if (!groupInfo.hasDuplicateNameToRemove) {
							hasDuplicateNameToRemove = true;
							break;
						}
					}
				}
				groupsByName.get(node.name).set(node, {
					node,
					hasDuplicateNameToRemove
				});
			}
		},
		exit({ node }, { openRefs }) {
			openRefs.delete(node.number);
		}
	},
	Group: {
		enter({ node }, state) {
			state.prevFlags = state.currentFlags;
			if (node.flags) {
				state.currentFlags = getNewCurrentFlags(state.currentFlags, node.flags);
			}
		},
		exit(_$2, state) {
			state.currentFlags = state.prevFlags;
		}
	},
	Subroutine({ node, parent, replaceWith }, state) {
		const { isRecursive, ref } = node;
		if (isRecursive) {
			let reffed = parent;
			while (reffed = reffed.parent) {
				if (reffed.type === "CapturingGroup" && (reffed.name === ref || reffed.number === ref)) {
					break;
				}
			}
			state.reffedNodesByReferencer.set(node, reffed);
			return;
		}
		const reffedGroupNode = state.subroutineRefMap.get(ref);
		const isGlobalRecursion = ref === 0;
		const expandedSubroutine = isGlobalRecursion ? createRecursion(0) : cloneCapturingGroup(reffedGroupNode, state.groupOriginByCopy, null);
		let replacement = expandedSubroutine;
		if (!isGlobalRecursion) {
			const reffedGroupFlagMods = getCombinedFlagModsFromFlagNodes(getAllParents(reffedGroupNode, (p$1) => p$1.type === "Group" && !!p$1.flags));
			const reffedGroupFlags = reffedGroupFlagMods ? getNewCurrentFlags(state.globalFlags, reffedGroupFlagMods) : state.globalFlags;
			if (!areFlagsEqual(reffedGroupFlags, state.currentFlags)) {
				replacement = A({ flags: getFlagModsFromFlags(reffedGroupFlags) });
				replacement.body[0].body.push(expandedSubroutine);
			}
		}
		replaceWith(setParentDeep(replacement, parent), { traverse: !isGlobalRecursion });
	}
};
var ThirdPassVisitor = {
	Backreference({ node, parent, replaceWith }, state) {
		if (node.orphan) {
			state.highestOrphanBackref = Math.max(state.highestOrphanBackref, node.ref);
			return;
		}
		const reffedNodes = state.reffedNodesByReferencer.get(node);
		const participants = reffedNodes.filter((reffed) => canParticipateWithNode(reffed, node));
		if (!participants.length) {
			replaceWith(setParentDeep(K({ negate: true }), parent));
		} else if (participants.length > 1) {
			const group = A({
				atomic: true,
				body: participants.reverse().map((reffed) => b({ body: [k(reffed.number)] }))
			});
			replaceWith(setParentDeep(group, parent));
		} else {
			node.ref = participants[0].number;
		}
	},
	CapturingGroup({ node }, state) {
		node.number = ++state.numCapturesToLeft;
		if (node.name) {
			if (state.groupsByName.get(node.name).get(node).hasDuplicateNameToRemove) {
				delete node.name;
			}
		}
	},
	Regex: { exit({ node }, state) {
		const numCapsNeeded = Math.max(state.highestOrphanBackref - state.numCapturesToLeft, 0);
		for (let i$2 = 0; i$2 < numCapsNeeded; i$2++) {
			const emptyCapture = P();
			node.body.at(-1).body.push(emptyCapture);
		}
	} },
	Subroutine({ node }, state) {
		if (!node.isRecursive || node.ref === 0) {
			return;
		}
		node.ref = state.reffedNodesByReferencer.get(node).number;
	}
};
function addParentProperties(root$1) {
	S(root$1, { "*"({ node, parent }) {
		node.parent = parent;
	} });
}
function areFlagsEqual(a$1, b$2) {
	return a$1.dotAll === b$2.dotAll && a$1.ignoreCase === b$2.ignoreCase;
}
function canParticipateWithNode(capture, node) {
	let rightmostPoint = node;
	do {
		if (rightmostPoint.type === "Regex") {
			return false;
		}
		if (rightmostPoint.type === "Alternative") {
			continue;
		}
		if (rightmostPoint === capture) {
			return false;
		}
		const kidsOfParent = getKids(rightmostPoint.parent);
		for (const kid of kidsOfParent) {
			if (kid === rightmostPoint) {
				break;
			}
			if (kid === capture || isAncestorOf(kid, capture)) {
				return true;
			}
		}
	} while (rightmostPoint = rightmostPoint.parent);
	throw new Error("Unexpected path");
}
function cloneCapturingGroup(obj, originMap, up, up2) {
	const store = Array.isArray(obj) ? [] : {};
	for (const [key$1, value] of Object.entries(obj)) {
		if (key$1 === "parent") {
			store.parent = Array.isArray(up) ? up2 : up;
		} else if (value && typeof value === "object") {
			store[key$1] = cloneCapturingGroup(value, originMap, store, up);
		} else {
			if (key$1 === "type" && value === "CapturingGroup") {
				originMap.set(store, originMap.get(obj) ?? obj);
			}
			store[key$1] = value;
		}
	}
	return store;
}
function createRecursion(ref) {
	const node = O(ref);
	node.isRecursive = true;
	return node;
}
function getAllParents(node, filterFn) {
	const results = [];
	while (node = node.parent) {
		if (!filterFn || filterFn(node)) {
			results.push(node);
		}
	}
	return results;
}
function getAndStoreJsGroupName(name, map) {
	if (map.has(name)) {
		return map.get(name);
	}
	const jsName = `$${map.size}_${name.replace(/^[^$_\p{IDS}]|[^$\u200C\u200D\p{IDC}]/gu, "_")}`;
	map.set(name, jsName);
	return jsName;
}
function getCombinedFlagModsFromFlagNodes(flagNodes) {
	const flagProps = ["dotAll", "ignoreCase"];
	const combinedFlags = {
		enable: {},
		disable: {}
	};
	flagNodes.forEach(({ flags }) => {
		flagProps.forEach((prop) => {
			if (flags.enable?.[prop]) {
				delete combinedFlags.disable[prop];
				combinedFlags.enable[prop] = true;
			}
			if (flags.disable?.[prop]) {
				combinedFlags.disable[prop] = true;
			}
		});
	});
	if (!Object.keys(combinedFlags.enable).length) {
		delete combinedFlags.enable;
	}
	if (!Object.keys(combinedFlags.disable).length) {
		delete combinedFlags.disable;
	}
	if (combinedFlags.enable || combinedFlags.disable) {
		return combinedFlags;
	}
	return null;
}
function getFlagModsFromFlags({ dotAll, ignoreCase }) {
	const mods = {};
	if (dotAll || ignoreCase) {
		mods.enable = {};
		dotAll && (mods.enable.dotAll = true);
		ignoreCase && (mods.enable.ignoreCase = true);
	}
	if (!dotAll || !ignoreCase) {
		mods.disable = {};
		!dotAll && (mods.disable.dotAll = true);
		!ignoreCase && (mods.disable.ignoreCase = true);
	}
	return mods;
}
function getKids(node) {
	if (!node) {
		throw new Error("Node expected");
	}
	const { body: body$2 } = node;
	return Array.isArray(body$2) ? body$2 : body$2 ? [body$2] : null;
}
function getLeadingG(els) {
	const firstToConsider = els.find((el) => el.kind === "search_start" || isLoneGLookaround(el, { negate: false }) || !isAlwaysZeroLength(el));
	if (!firstToConsider) {
		return null;
	}
	if (firstToConsider.kind === "search_start") {
		return firstToConsider;
	}
	if (firstToConsider.type === "LookaroundAssertion") {
		return firstToConsider.body[0].body[0];
	}
	if (firstToConsider.type === "CapturingGroup" || firstToConsider.type === "Group") {
		const gNodesForGroup = [];
		for (const alt of firstToConsider.body) {
			const leadingG = getLeadingG(alt.body);
			if (!leadingG) {
				return null;
			}
			Array.isArray(leadingG) ? gNodesForGroup.push(...leadingG) : gNodesForGroup.push(leadingG);
		}
		return gNodesForGroup;
	}
	return null;
}
function isAncestorOf(node, descendant) {
	const kids = getKids(node) ?? [];
	for (const kid of kids) {
		if (kid === descendant || isAncestorOf(kid, descendant)) {
			return true;
		}
	}
	return false;
}
function isAlwaysZeroLength({ type }) {
	return type === "Assertion" || type === "Directive" || type === "LookaroundAssertion";
}
function isAlwaysNonZeroLength(node) {
	const types = [
		"Character",
		"CharacterClass",
		"CharacterSet"
	];
	return types.includes(node.type) || node.type === "Quantifier" && node.min && types.includes(node.body.type);
}
function isLoneGLookaround(node, options) {
	const opts = {
		negate: null,
		...options
	};
	return node.type === "LookaroundAssertion" && (opts.negate === null || node.negate === opts.negate) && node.body.length === 1 && o(node.body[0], {
		type: "Assertion",
		kind: "search_start"
	});
}
function isValidJsGroupName(name) {
	return /^[$_\p{IDS}][$\u200C\u200D\p{IDC}]*$/u.test(name);
}
function parseFragment(pattern, options) {
	const ast = J(pattern, {
		...options,
		unicodePropertyMap: JsUnicodePropertyMap
	});
	const alts = ast.body;
	if (alts.length > 1 || alts[0].body.length > 1) {
		return A({ body: alts });
	}
	return alts[0].body[0];
}
function setNegate(node, negate) {
	node.negate = negate;
	return node;
}
function setParent(node, parent) {
	node.parent = parent;
	return node;
}
function setParentDeep(node, parent) {
	addParentProperties(node);
	node.parent = parent;
	return node;
}
function generate(ast, options) {
	const opts = getOptions(options);
	const minTargetEs2024 = isMinTarget(opts.target, "ES2024");
	const minTargetEs2025 = isMinTarget(opts.target, "ES2025");
	const recursionLimit = opts.rules.recursionLimit;
	if (!Number.isInteger(recursionLimit) || recursionLimit < 2 || recursionLimit > 20) {
		throw new Error("Invalid recursionLimit; use 2-20");
	}
	let hasCaseInsensitiveNode = null;
	let hasCaseSensitiveNode = null;
	if (!minTargetEs2025) {
		const iStack = [ast.flags.ignoreCase];
		S(ast, FlagModifierVisitor, {
			getCurrentModI: () => iStack.at(-1),
			popModI() {
				iStack.pop();
			},
			pushModI(isIOn) {
				iStack.push(isIOn);
			},
			setHasCasedChar() {
				if (iStack.at(-1)) {
					hasCaseInsensitiveNode = true;
				} else {
					hasCaseSensitiveNode = true;
				}
			}
		});
	}
	const appliedGlobalFlags = {
		dotAll: ast.flags.dotAll,
		ignoreCase: !!((ast.flags.ignoreCase || hasCaseInsensitiveNode) && !hasCaseSensitiveNode)
	};
	let lastNode = ast;
	const state = {
		accuracy: opts.accuracy,
		appliedGlobalFlags,
		captureMap: /* @__PURE__ */ new Map(),
		currentFlags: {
			dotAll: ast.flags.dotAll,
			ignoreCase: ast.flags.ignoreCase
		},
		inCharClass: false,
		lastNode,
		originMap: ast._originMap,
		recursionLimit,
		useAppliedIgnoreCase: !!(!minTargetEs2025 && hasCaseInsensitiveNode && hasCaseSensitiveNode),
		useFlagMods: minTargetEs2025,
		useFlagV: minTargetEs2024,
		verbose: opts.verbose
	};
	function gen(node) {
		state.lastNode = lastNode;
		lastNode = node;
		const fn = throwIfNullish(generator[node.type], `Unexpected node type "${node.type}"`);
		return fn(node, state, gen);
	}
	const result = {
		pattern: ast.body.map(gen).join("|"),
		flags: gen(ast.flags),
		options: { ...ast.options }
	};
	if (!minTargetEs2024) {
		delete result.options.force.v;
		result.options.disable.v = true;
		result.options.unicodeSetsPlugin = null;
	}
	result._captureTransfers = /* @__PURE__ */ new Map();
	result._hiddenCaptures = [];
	state.captureMap.forEach((value, key$1) => {
		if (value.hidden) {
			result._hiddenCaptures.push(key$1);
		}
		if (value.transferTo) {
			getOrInsert(result._captureTransfers, value.transferTo, []).push(key$1);
		}
	});
	return result;
}
var FlagModifierVisitor = {
	"*": {
		enter({ node }, state) {
			if (isAnyGroup(node)) {
				const currentModI = state.getCurrentModI();
				state.pushModI(node.flags ? getNewCurrentFlags({ ignoreCase: currentModI }, node.flags).ignoreCase : currentModI);
			}
		},
		exit({ node }, state) {
			if (isAnyGroup(node)) {
				state.popModI();
			}
		}
	},
	Backreference(_$2, state) {
		state.setHasCasedChar();
	},
	Character({ node }, state) {
		if (charHasCase(cp(node.value))) {
			state.setHasCasedChar();
		}
	},
	CharacterClassRange({ node, skip }, state) {
		skip();
		if (getCasesOutsideCharClassRange(node, { firstOnly: true }).length) {
			state.setHasCasedChar();
		}
	},
	CharacterSet({ node }, state) {
		if (node.kind === "property" && UnicodePropertiesWithSpecificCase.has(node.value)) {
			state.setHasCasedChar();
		}
	}
};
var generator = {
	Alternative({ body: body$2 }, _$2, gen) {
		return body$2.map(gen).join("");
	},
	Assertion({ kind, negate }) {
		if (kind === "string_end") {
			return "$";
		}
		if (kind === "string_start") {
			return "^";
		}
		if (kind === "word_boundary") {
			return negate ? r`\B` : r`\b`;
		}
		throw new Error(`Unexpected assertion kind "${kind}"`);
	},
	Backreference({ ref }, state) {
		if (typeof ref !== "number") {
			throw new Error("Unexpected named backref in transformed AST");
		}
		if (!state.useFlagMods && state.accuracy === "strict" && state.currentFlags.ignoreCase && !state.captureMap.get(ref).ignoreCase) {
			throw new Error("Use of case-insensitive backref to case-sensitive group requires target ES2025 or non-strict accuracy");
		}
		return "\\" + ref;
	},
	CapturingGroup(node, state, gen) {
		const { body: body$2, name, number: number$1 } = node;
		const data = { ignoreCase: state.currentFlags.ignoreCase };
		const origin = state.originMap.get(node);
		if (origin) {
			data.hidden = true;
			if (number$1 > origin.number) {
				data.transferTo = origin.number;
			}
		}
		state.captureMap.set(number$1, data);
		return `(${name ? `?<${name}>` : ""}${body$2.map(gen).join("|")})`;
	},
	Character({ value }, state) {
		const char = cp(value);
		const escaped = getCharEscape(value, {
			escDigit: state.lastNode.type === "Backreference",
			inCharClass: state.inCharClass,
			useFlagV: state.useFlagV
		});
		if (escaped !== char) {
			return escaped;
		}
		if (state.useAppliedIgnoreCase && state.currentFlags.ignoreCase && charHasCase(char)) {
			const cases = getIgnoreCaseMatchChars(char);
			return state.inCharClass ? cases.join("") : cases.length > 1 ? `[${cases.join("")}]` : cases[0];
		}
		return char;
	},
	CharacterClass(node, state, gen) {
		const { kind, negate, parent } = node;
		let { body: body$2 } = node;
		if (kind === "intersection" && !state.useFlagV) {
			throw new Error("Use of character class intersection requires min target ES2024");
		}
		if (envFlags.bugFlagVLiteralHyphenIsRange && state.useFlagV && body$2.some(isLiteralHyphen)) {
			body$2 = [m(45), ...body$2.filter((kid) => !isLiteralHyphen(kid))];
		}
		const genClass = () => `[${negate ? "^" : ""}${body$2.map(gen).join(kind === "intersection" ? "&&" : "")}]`;
		if (!state.inCharClass) {
			if ((!state.useFlagV || envFlags.bugNestedClassIgnoresNegation) && !negate) {
				const negatedChildClasses = body$2.filter((kid) => kid.type === "CharacterClass" && kid.kind === "union" && kid.negate);
				if (negatedChildClasses.length) {
					const group = A();
					const groupFirstAlt = group.body[0];
					group.parent = parent;
					groupFirstAlt.parent = group;
					body$2 = body$2.filter((kid) => !negatedChildClasses.includes(kid));
					node.body = body$2;
					if (body$2.length) {
						node.parent = groupFirstAlt;
						groupFirstAlt.body.push(node);
					} else {
						group.body.pop();
					}
					negatedChildClasses.forEach((cc) => {
						const newAlt = b({ body: [cc] });
						cc.parent = newAlt;
						newAlt.parent = group;
						group.body.push(newAlt);
					});
					return gen(group);
				}
			}
			state.inCharClass = true;
			const result = genClass();
			state.inCharClass = false;
			return result;
		}
		const firstEl = body$2[0];
		if (kind === "union" && !negate && firstEl && ((!state.useFlagV || !state.verbose) && parent.kind === "union" && !(envFlags.bugFlagVLiteralHyphenIsRange && state.useFlagV) || !state.verbose && parent.kind === "intersection" && body$2.length === 1 && firstEl.type !== "CharacterClassRange")) {
			return body$2.map(gen).join("");
		}
		if (!state.useFlagV && parent.type === "CharacterClass") {
			throw new Error("Uses nested character class in a way that requires min target ES2024");
		}
		return genClass();
	},
	CharacterClassRange(node, state) {
		const min = node.min.value;
		const max = node.max.value;
		const escOpts = {
			escDigit: false,
			inCharClass: true,
			useFlagV: state.useFlagV
		};
		const minStr = getCharEscape(min, escOpts);
		const maxStr = getCharEscape(max, escOpts);
		const extraChars = /* @__PURE__ */ new Set();
		if (state.useAppliedIgnoreCase && state.currentFlags.ignoreCase) {
			const charsOutsideRange = getCasesOutsideCharClassRange(node);
			const ranges = getCodePointRangesFromChars(charsOutsideRange);
			ranges.forEach((value) => {
				extraChars.add(Array.isArray(value) ? `${getCharEscape(value[0], escOpts)}-${getCharEscape(value[1], escOpts)}` : getCharEscape(value, escOpts));
			});
		}
		return `${minStr}-${maxStr}${[...extraChars].join("")}`;
	},
	CharacterSet({ kind, negate, value, key: key$1 }, state) {
		if (kind === "dot") {
			return state.currentFlags.dotAll ? state.appliedGlobalFlags.dotAll || state.useFlagMods ? "." : "[^]" : r`[^\n]`;
		}
		if (kind === "digit") {
			return negate ? r`\D` : r`\d`;
		}
		if (kind === "property") {
			if (state.useAppliedIgnoreCase && state.currentFlags.ignoreCase && UnicodePropertiesWithSpecificCase.has(value)) {
				throw new Error(`Unicode property "${value}" can't be case-insensitive when other chars have specific case`);
			}
			return `${negate ? r`\P` : r`\p`}{${key$1 ? `${key$1}=` : ""}${value}}`;
		}
		if (kind === "word") {
			return negate ? r`\W` : r`\w`;
		}
		throw new Error(`Unexpected character set kind "${kind}"`);
	},
	Flags(node, state) {
		return (state.appliedGlobalFlags.ignoreCase ? "i" : "") + (node.dotAll ? "s" : "") + (node.sticky ? "y" : "");
	},
	Group({ atomic: atomic2, body: body$2, flags, parent }, state, gen) {
		const currentFlags = state.currentFlags;
		if (flags) {
			state.currentFlags = getNewCurrentFlags(currentFlags, flags);
		}
		const contents = body$2.map(gen).join("|");
		const result = !state.verbose && body$2.length === 1 && parent.type !== "Quantifier" && !atomic2 && (!state.useFlagMods || !flags) ? contents : `(?${getGroupPrefix(atomic2, flags, state.useFlagMods)}${contents})`;
		state.currentFlags = currentFlags;
		return result;
	},
	LookaroundAssertion({ body: body$2, kind, negate }, _$2, gen) {
		const prefix = `${kind === "lookahead" ? "" : "<"}${negate ? "!" : "="}`;
		return `(?${prefix}${body$2.map(gen).join("|")})`;
	},
	Quantifier(node, _$2, gen) {
		return gen(node.body) + getQuantifierStr(node);
	},
	Subroutine({ isRecursive, ref }, state) {
		if (!isRecursive) {
			throw new Error("Unexpected non-recursive subroutine in transformed AST");
		}
		const limit = state.recursionLimit;
		return ref === 0 ? `(?R=${limit})` : r`\g<${ref}&R=${limit}>`;
	}
};
var BaseEscapeChars = /* @__PURE__ */ new Set([
	"$",
	"(",
	")",
	"*",
	"+",
	".",
	"?",
	"[",
	"\\",
	"]",
	"^",
	"{",
	"|",
	"}"
]);
var CharClassEscapeChars = /* @__PURE__ */ new Set([
	"-",
	"\\",
	"]",
	"^",
	"["
]);
var CharClassEscapeCharsFlagV = /* @__PURE__ */ new Set([
	"(",
	")",
	"-",
	"/",
	"[",
	"\\",
	"]",
	"^",
	"{",
	"|",
	"}",
	"!",
	"#",
	"$",
	"%",
	"&",
	"*",
	"+",
	",",
	".",
	":",
	";",
	"<",
	"=",
	">",
	"?",
	"@",
	"`",
	"~"
]);
var CharCodeEscapeMap = /* @__PURE__ */ new Map([
	[9, r`\t`],
	[10, r`\n`],
	[11, r`\v`],
	[12, r`\f`],
	[13, r`\r`],
	[8232, r`\u2028`],
	[8233, r`\u2029`],
	[65279, r`\uFEFF`]
]);
var casedRe = /^\p{Cased}$/u;
function charHasCase(char) {
	return casedRe.test(char);
}
function getCasesOutsideCharClassRange(node, options) {
	const firstOnly = !!options?.firstOnly;
	const min = node.min.value;
	const max = node.max.value;
	const found = [];
	if (min < 65 && (max === 65535 || max >= 131071) || min === 65536 && max >= 131071) {
		return found;
	}
	for (let i$2 = min; i$2 <= max; i$2++) {
		const char = cp(i$2);
		if (!charHasCase(char)) {
			continue;
		}
		const charsOutsideRange = getIgnoreCaseMatchChars(char).filter((caseOfChar) => {
			const num = caseOfChar.codePointAt(0);
			return num < min || num > max;
		});
		if (charsOutsideRange.length) {
			found.push(...charsOutsideRange);
			if (firstOnly) {
				break;
			}
		}
	}
	return found;
}
function getCharEscape(codePoint, { escDigit, inCharClass, useFlagV }) {
	if (CharCodeEscapeMap.has(codePoint)) {
		return CharCodeEscapeMap.get(codePoint);
	}
	if (codePoint < 32 || codePoint > 126 && codePoint < 160 || codePoint > 262143 || escDigit && isDigitCharCode(codePoint)) {
		return codePoint > 255 ? `\\u{${codePoint.toString(16).toUpperCase()}}` : `\\x${codePoint.toString(16).toUpperCase().padStart(2, "0")}`;
	}
	const escapeChars = inCharClass ? useFlagV ? CharClassEscapeCharsFlagV : CharClassEscapeChars : BaseEscapeChars;
	const char = cp(codePoint);
	return (escapeChars.has(char) ? "\\" : "") + char;
}
function getCodePointRangesFromChars(chars) {
	const codePoints = chars.map((char) => char.codePointAt(0)).sort((a$1, b$2) => a$1 - b$2);
	const values = [];
	let start = null;
	for (let i$2 = 0; i$2 < codePoints.length; i$2++) {
		if (codePoints[i$2 + 1] === codePoints[i$2] + 1) {
			start ??= codePoints[i$2];
		} else if (start === null) {
			values.push(codePoints[i$2]);
		} else {
			values.push([start, codePoints[i$2]]);
			start = null;
		}
	}
	return values;
}
function getGroupPrefix(atomic2, flagMods, useFlagMods) {
	if (atomic2) {
		return ">";
	}
	let mods = "";
	if (flagMods && useFlagMods) {
		const { enable, disable } = flagMods;
		mods = (enable?.ignoreCase ? "i" : "") + (enable?.dotAll ? "s" : "") + (disable ? "-" : "") + (disable?.ignoreCase ? "i" : "") + (disable?.dotAll ? "s" : "");
	}
	return `${mods}:`;
}
function getQuantifierStr({ kind, max, min }) {
	let base;
	if (!min && max === 1) {
		base = "?";
	} else if (!min && max === Infinity) {
		base = "*";
	} else if (min === 1 && max === Infinity) {
		base = "+";
	} else if (min === max) {
		base = `{${min}}`;
	} else {
		base = `{${min},${max === Infinity ? "" : max}}`;
	}
	return base + {
		greedy: "",
		lazy: "?",
		possessive: "+"
	}[kind];
}
function isAnyGroup({ type }) {
	return type === "CapturingGroup" || type === "Group" || type === "LookaroundAssertion";
}
function isDigitCharCode(value) {
	return value > 47 && value < 58;
}
function isLiteralHyphen({ type, value }) {
	return type === "Character" && value === 45;
}
var EmulatedRegExp = class _EmulatedRegExp extends RegExp {
	/**
	@type {Map<number, {
	hidden?: true;
	transferTo?: number;
	}>}
	*/
	#captureMap = /* @__PURE__ */ new Map();
	/**
	@type {RegExp | EmulatedRegExp | null}
	*/
	#compiled = null;
	/**
	@type {string}
	*/
	#pattern;
	/**
	@type {Map<number, string>?}
	*/
	#nameMap = null;
	/**
	@type {string?}
	*/
	#strategy = null;
	/**
	Can be used to serialize the instance.
	@type {EmulatedRegExpOptions}
	*/
	rawOptions = {};
	get source() {
		return this.#pattern || "(?:)";
	}
	/**
	@overload
	@param {string} pattern
	@param {string} [flags]
	@param {EmulatedRegExpOptions} [options]
	*/
	/**
	@overload
	@param {EmulatedRegExp} pattern
	@param {string} [flags]
	*/
	constructor(pattern, flags, options) {
		const lazyCompile = !!options?.lazyCompile;
		if (pattern instanceof RegExp) {
			if (options) {
				throw new Error("Cannot provide options when copying a regexp");
			}
			const re$2 = pattern;
			super(re$2, flags);
			this.#pattern = re$2.source;
			if (re$2 instanceof _EmulatedRegExp) {
				this.#captureMap = re$2.#captureMap;
				this.#nameMap = re$2.#nameMap;
				this.#strategy = re$2.#strategy;
				this.rawOptions = re$2.rawOptions;
			}
		} else {
			const opts = {
				hiddenCaptures: [],
				strategy: null,
				transfers: [],
				...options
			};
			super(lazyCompile ? "" : pattern, flags);
			this.#pattern = pattern;
			this.#captureMap = createCaptureMap(opts.hiddenCaptures, opts.transfers);
			this.#strategy = opts.strategy;
			this.rawOptions = options ?? {};
		}
		if (!lazyCompile) {
			this.#compiled = this;
		}
	}
	/**
	Called internally by all String/RegExp methods that use regexes.
	@override
	@param {string} str
	@returns {RegExpExecArray?}
	*/
	exec(str) {
		if (!this.#compiled) {
			const { lazyCompile,...rest } = this.rawOptions;
			this.#compiled = new _EmulatedRegExp(this.#pattern, this.flags, rest);
		}
		const useLastIndex = this.global || this.sticky;
		const pos = this.lastIndex;
		if (this.#strategy === "clip_search" && useLastIndex && pos) {
			this.lastIndex = 0;
			const match = this.#execCore(str.slice(pos));
			if (match) {
				adjustMatchDetailsForOffset(match, pos, str, this.hasIndices);
				this.lastIndex += pos;
			}
			return match;
		}
		return this.#execCore(str);
	}
	/**
	Adds support for hidden and transfer captures.
	@param {string} str
	@returns
	*/
	#execCore(str) {
		this.#compiled.lastIndex = this.lastIndex;
		const match = super.exec.call(this.#compiled, str);
		this.lastIndex = this.#compiled.lastIndex;
		if (!match || !this.#captureMap.size) {
			return match;
		}
		const matchCopy = [...match];
		match.length = 1;
		let indicesCopy;
		if (this.hasIndices) {
			indicesCopy = [...match.indices];
			match.indices.length = 1;
		}
		const mappedNums = [0];
		for (let i$2 = 1; i$2 < matchCopy.length; i$2++) {
			const { hidden, transferTo } = this.#captureMap.get(i$2) ?? {};
			if (hidden) {
				mappedNums.push(null);
			} else {
				mappedNums.push(match.length);
				match.push(matchCopy[i$2]);
				if (this.hasIndices) {
					match.indices.push(indicesCopy[i$2]);
				}
			}
			if (transferTo && matchCopy[i$2] !== void 0) {
				const to = mappedNums[transferTo];
				if (!to) {
					throw new Error(`Invalid capture transfer to "${to}"`);
				}
				match[to] = matchCopy[i$2];
				if (this.hasIndices) {
					match.indices[to] = indicesCopy[i$2];
				}
				if (match.groups) {
					if (!this.#nameMap) {
						this.#nameMap = createNameMap(this.source);
					}
					const name = this.#nameMap.get(transferTo);
					if (name) {
						match.groups[name] = matchCopy[i$2];
						if (this.hasIndices) {
							match.indices.groups[name] = indicesCopy[i$2];
						}
					}
				}
			}
		}
		return match;
	}
};
function adjustMatchDetailsForOffset(match, offset, input, hasIndices) {
	match.index += offset;
	match.input = input;
	if (hasIndices) {
		const indices = match.indices;
		for (let i$2 = 0; i$2 < indices.length; i$2++) {
			const arr = indices[i$2];
			if (arr) {
				indices[i$2] = [arr[0] + offset, arr[1] + offset];
			}
		}
		const groupIndices = indices.groups;
		if (groupIndices) {
			Object.keys(groupIndices).forEach((key$1) => {
				const arr = groupIndices[key$1];
				if (arr) {
					groupIndices[key$1] = [arr[0] + offset, arr[1] + offset];
				}
			});
		}
	}
}
function createCaptureMap(hiddenCaptures, transfers) {
	const captureMap = /* @__PURE__ */ new Map();
	for (const num of hiddenCaptures) {
		captureMap.set(num, { hidden: true });
	}
	for (const [to, from] of transfers) {
		for (const num of from) {
			getOrInsert(captureMap, num, {}).transferTo = to;
		}
	}
	return captureMap;
}
function createNameMap(pattern) {
	const re$2 = /(?<capture>\((?:\?<(?![=!])(?<name>[^>]+)>|(?!\?)))|\\?./gsu;
	const map = /* @__PURE__ */ new Map();
	let numCharClassesOpen = 0;
	let numCaptures = 0;
	let match;
	while (match = re$2.exec(pattern)) {
		const { 0: m$2, groups: { capture, name } } = match;
		if (m$2 === "[") {
			numCharClassesOpen++;
		} else if (!numCharClassesOpen) {
			if (capture) {
				numCaptures++;
				if (name) {
					map.set(numCaptures, name);
				}
			}
		} else if (m$2 === "]") {
			numCharClassesOpen--;
		}
	}
	return map;
}
function toRegExp(pattern, options) {
	const d$1 = toRegExpDetails(pattern, options);
	if (d$1.options) {
		return new EmulatedRegExp(d$1.pattern, d$1.flags, d$1.options);
	}
	return new RegExp(d$1.pattern, d$1.flags);
}
function toRegExpDetails(pattern, options) {
	const opts = getOptions(options);
	const onigurumaAst = J(pattern, {
		flags: opts.flags,
		normalizeUnknownPropertyNames: true,
		rules: {
			captureGroup: opts.rules.captureGroup,
			singleline: opts.rules.singleline
		},
		skipBackrefValidation: opts.rules.allowOrphanBackrefs,
		unicodePropertyMap: JsUnicodePropertyMap
	});
	const regexPlusAst = transform(onigurumaAst, {
		accuracy: opts.accuracy,
		asciiWordBoundaries: opts.rules.asciiWordBoundaries,
		avoidSubclass: opts.avoidSubclass,
		bestEffortTarget: opts.target
	});
	const generated = generate(regexPlusAst, opts);
	const recursionResult = recursion(generated.pattern, {
		captureTransfers: generated._captureTransfers,
		hiddenCaptures: generated._hiddenCaptures,
		mode: "external"
	});
	const possessiveResult = possessive(recursionResult.pattern);
	const atomicResult = atomic(possessiveResult.pattern, {
		captureTransfers: recursionResult.captureTransfers,
		hiddenCaptures: recursionResult.hiddenCaptures
	});
	const details = {
		pattern: atomicResult.pattern,
		flags: `${opts.hasIndices ? "d" : ""}${opts.global ? "g" : ""}${generated.flags}${generated.options.disable.v ? "u" : "v"}`
	};
	if (opts.avoidSubclass) {
		if (opts.lazyCompileLength !== Infinity) {
			throw new Error("Lazy compilation requires subclass");
		}
	} else {
		const hiddenCaptures = atomicResult.hiddenCaptures.sort((a$1, b$2) => a$1 - b$2);
		const transfers = Array.from(atomicResult.captureTransfers);
		const strategy = regexPlusAst._strategy;
		const lazyCompile = details.pattern.length >= opts.lazyCompileLength;
		if (hiddenCaptures.length || transfers.length || strategy || lazyCompile) {
			details.options = {
				...hiddenCaptures.length && { hiddenCaptures },
				...transfers.length && { transfers },
				...strategy && { strategy },
				...lazyCompile && { lazyCompile }
			};
		}
	}
	return details;
}

//#endregion
//#region ../../node_modules/.bun/@shikijs+engine-javascript@4.0.2/node_modules/@shikijs/engine-javascript/dist/engine-compile.mjs
/**
* The default regex constructor for the JavaScript RegExp engine.
*/
function defaultJavaScriptRegexConstructor(pattern, options) {
	return toRegExp(pattern, {
		global: true,
		hasIndices: true,
		lazyCompileLength: 3e3,
		rules: {
			allowOrphanBackrefs: true,
			asciiWordBoundaries: true,
			captureGroup: true,
			recursionLimit: 5,
			singleline: true
		},
		...options
	});
}
/**
* Use the modern JavaScript RegExp engine to implement the OnigScanner.
*
* As Oniguruma supports some features that can't be emulated using native JavaScript regexes, some
* patterns are not supported. Errors will be thrown when parsing TextMate grammars with
* unsupported patterns, and when the grammar includes patterns that use invalid Oniguruma syntax.
* Set `forgiving` to `true` to ignore these errors and skip any unsupported or invalid patterns.
*/
function createJavaScriptRegexEngine(options = {}) {
	const _options = Object.assign({
		target: "auto",
		cache: /* @__PURE__ */ new Map()
	}, options);
	_options.regexConstructor ||= (pattern) => defaultJavaScriptRegexConstructor(pattern, { target: _options.target });
	return {
		createScanner(patterns) {
			return new JavaScriptScanner(patterns, _options);
		},
		createString(s$1) {
			return { content: s$1 };
		}
	};
}

//#endregion
//#region ../../node_modules/.bun/@shikijs+engine-javascript@4.0.2/node_modules/@shikijs/engine-javascript/dist/engine-raw.mjs
/**
* Raw JavaScript regex engine that only supports precompiled grammars.
*
* This further simplifies the engine by excluding the regex compilation step.
*
* Zero dependencies.
*/
function createJavaScriptRawEngine() {
	const options = {
		cache: /* @__PURE__ */ new Map(),
		regexConstructor: () => {
			throw new Error("JavaScriptRawEngine: only support precompiled grammar");
		}
	};
	return {
		createScanner(patterns) {
			return new JavaScriptScanner(patterns, options);
		},
		createString(s$1) {
			return { content: s$1 };
		}
	};
}

//#endregion
//#region ../../node_modules/.bun/@shikijs+engine-oniguruma@4.0.2/node_modules/@shikijs/engine-oniguruma/dist/index.mjs
var dist_exports = /* @__PURE__ */ __export({
	createOnigurumaEngine: () => createOnigurumaEngine,
	getDefaultWasmLoader: () => getDefaultWasmLoader,
	loadWasm: () => loadWasm,
	setDefaultWasmLoader: () => setDefaultWasmLoader
});
var ShikiError = class extends Error {
	constructor(message) {
		super(message);
		this.name = "ShikiError";
	}
};
function getHeapMax() {
	return 2147483648;
}
function _emscripten_get_now() {
	return typeof performance !== "undefined" ? performance.now() : Date.now();
}
const alignUp = (x$1, multiple) => x$1 + (multiple - x$1 % multiple) % multiple;
async function main(init) {
	let wasmMemory;
	let buffer;
	const binding = {};
	function updateGlobalBufferAndViews(buf) {
		buffer = buf;
		binding.HEAPU8 = new Uint8Array(buf);
		binding.HEAPU32 = new Uint32Array(buf);
	}
	function _emscripten_memcpy_big(dest, src, num) {
		binding.HEAPU8.copyWithin(dest, src, src + num);
	}
	function emscripten_realloc_buffer(size) {
		try {
			wasmMemory.grow(size - buffer.byteLength + 65535 >>> 16);
			updateGlobalBufferAndViews(wasmMemory.buffer);
			return 1;
		} catch {}
	}
	function _emscripten_resize_heap(requestedSize) {
		const oldSize = binding.HEAPU8.length;
		requestedSize = requestedSize >>> 0;
		const maxHeapSize = getHeapMax();
		if (requestedSize > maxHeapSize) return false;
		for (let cutDown = 1; cutDown <= 4; cutDown *= 2) {
			let overGrownHeapSize = oldSize * (1 + .2 / cutDown);
			overGrownHeapSize = Math.min(overGrownHeapSize, requestedSize + 100663296);
			const newSize = Math.min(maxHeapSize, alignUp(Math.max(requestedSize, overGrownHeapSize), 65536));
			const replacement = emscripten_realloc_buffer(newSize);
			if (replacement) return true;
		}
		return false;
	}
	const UTF8Decoder = typeof TextDecoder != "undefined" ? new TextDecoder("utf8") : void 0;
	function UTF8ArrayToString(heapOrArray, idx, maxBytesToRead = 1024) {
		const endIdx = idx + maxBytesToRead;
		let endPtr = idx;
		while (heapOrArray[endPtr] && !(endPtr >= endIdx)) ++endPtr;
		if (endPtr - idx > 16 && heapOrArray.buffer && UTF8Decoder) {
			return UTF8Decoder.decode(heapOrArray.subarray(idx, endPtr));
		}
		let str = "";
		while (idx < endPtr) {
			let u0 = heapOrArray[idx++];
			if (!(u0 & 128)) {
				str += String.fromCharCode(u0);
				continue;
			}
			const u1 = heapOrArray[idx++] & 63;
			if ((u0 & 224) === 192) {
				str += String.fromCharCode((u0 & 31) << 6 | u1);
				continue;
			}
			const u2 = heapOrArray[idx++] & 63;
			if ((u0 & 240) === 224) {
				u0 = (u0 & 15) << 12 | u1 << 6 | u2;
			} else {
				u0 = (u0 & 7) << 18 | u1 << 12 | u2 << 6 | heapOrArray[idx++] & 63;
			}
			if (u0 < 65536) {
				str += String.fromCharCode(u0);
			} else {
				const ch = u0 - 65536;
				str += String.fromCharCode(55296 | ch >> 10, 56320 | ch & 1023);
			}
		}
		return str;
	}
	function UTF8ToString(ptr, maxBytesToRead) {
		return ptr ? UTF8ArrayToString(binding.HEAPU8, ptr, maxBytesToRead) : "";
	}
	const asmLibraryArg = {
		emscripten_get_now: _emscripten_get_now,
		emscripten_memcpy_big: _emscripten_memcpy_big,
		emscripten_resize_heap: _emscripten_resize_heap,
		fd_write: () => 0
	};
	async function createWasm() {
		const info = {
			env: asmLibraryArg,
			wasi_snapshot_preview1: asmLibraryArg
		};
		const exports$1 = await init(info);
		wasmMemory = exports$1.memory;
		updateGlobalBufferAndViews(wasmMemory.buffer);
		Object.assign(binding, exports$1);
		binding.UTF8ToString = UTF8ToString;
	}
	await createWasm();
	return binding;
}
var __defProp = Object.defineProperty;
var __defNormalProp = (obj, key$1, value) => key$1 in obj ? __defProp(obj, key$1, {
	enumerable: true,
	configurable: true,
	writable: true,
	value
}) : obj[key$1] = value;
var __publicField = (obj, key$1, value) => __defNormalProp(obj, typeof key$1 !== "symbol" ? key$1 + "" : key$1, value);
let onigBinding = null;
function throwLastOnigError(onigBinding2) {
	throw new ShikiError(onigBinding2.UTF8ToString(onigBinding2.getLastOnigError()));
}
var UtfString = class UtfString {
	constructor(str) {
		__publicField(this, "utf16Length");
		__publicField(this, "utf8Length");
		__publicField(this, "utf16Value");
		__publicField(this, "utf8Value");
		__publicField(this, "utf16OffsetToUtf8");
		__publicField(this, "utf8OffsetToUtf16");
		const utf16Length = str.length;
		const utf8Length = UtfString._utf8ByteLength(str);
		const computeIndicesMapping = utf8Length !== utf16Length;
		const utf16OffsetToUtf8 = computeIndicesMapping ? new Uint32Array(utf16Length + 1) : null;
		if (computeIndicesMapping) utf16OffsetToUtf8[utf16Length] = utf8Length;
		const utf8OffsetToUtf16 = computeIndicesMapping ? new Uint32Array(utf8Length + 1) : null;
		if (computeIndicesMapping) utf8OffsetToUtf16[utf8Length] = utf16Length;
		const utf8Value = new Uint8Array(utf8Length);
		let i8 = 0;
		for (let i16 = 0; i16 < utf16Length; i16++) {
			const charCode = str.charCodeAt(i16);
			let codePoint = charCode;
			let wasSurrogatePair = false;
			if (charCode >= 55296 && charCode <= 56319) {
				if (i16 + 1 < utf16Length) {
					const nextCharCode = str.charCodeAt(i16 + 1);
					if (nextCharCode >= 56320 && nextCharCode <= 57343) {
						codePoint = (charCode - 55296 << 10) + 65536 | nextCharCode - 56320;
						wasSurrogatePair = true;
					}
				}
			}
			if (computeIndicesMapping) {
				utf16OffsetToUtf8[i16] = i8;
				if (wasSurrogatePair) utf16OffsetToUtf8[i16 + 1] = i8;
				if (codePoint <= 127) {
					utf8OffsetToUtf16[i8 + 0] = i16;
				} else if (codePoint <= 2047) {
					utf8OffsetToUtf16[i8 + 0] = i16;
					utf8OffsetToUtf16[i8 + 1] = i16;
				} else if (codePoint <= 65535) {
					utf8OffsetToUtf16[i8 + 0] = i16;
					utf8OffsetToUtf16[i8 + 1] = i16;
					utf8OffsetToUtf16[i8 + 2] = i16;
				} else {
					utf8OffsetToUtf16[i8 + 0] = i16;
					utf8OffsetToUtf16[i8 + 1] = i16;
					utf8OffsetToUtf16[i8 + 2] = i16;
					utf8OffsetToUtf16[i8 + 3] = i16;
				}
			}
			if (codePoint <= 127) {
				utf8Value[i8++] = codePoint;
			} else if (codePoint <= 2047) {
				utf8Value[i8++] = 192 | (codePoint & 1984) >>> 6;
				utf8Value[i8++] = 128 | (codePoint & 63) >>> 0;
			} else if (codePoint <= 65535) {
				utf8Value[i8++] = 224 | (codePoint & 61440) >>> 12;
				utf8Value[i8++] = 128 | (codePoint & 4032) >>> 6;
				utf8Value[i8++] = 128 | (codePoint & 63) >>> 0;
			} else {
				utf8Value[i8++] = 240 | (codePoint & 1835008) >>> 18;
				utf8Value[i8++] = 128 | (codePoint & 258048) >>> 12;
				utf8Value[i8++] = 128 | (codePoint & 4032) >>> 6;
				utf8Value[i8++] = 128 | (codePoint & 63) >>> 0;
			}
			if (wasSurrogatePair) i16++;
		}
		this.utf16Length = utf16Length;
		this.utf8Length = utf8Length;
		this.utf16Value = str;
		this.utf8Value = utf8Value;
		this.utf16OffsetToUtf8 = utf16OffsetToUtf8;
		this.utf8OffsetToUtf16 = utf8OffsetToUtf16;
	}
	static _utf8ByteLength(str) {
		let result = 0;
		for (let i$2 = 0, len = str.length; i$2 < len; i$2++) {
			const charCode = str.charCodeAt(i$2);
			let codepoint = charCode;
			let wasSurrogatePair = false;
			if (charCode >= 55296 && charCode <= 56319) {
				if (i$2 + 1 < len) {
					const nextCharCode = str.charCodeAt(i$2 + 1);
					if (nextCharCode >= 56320 && nextCharCode <= 57343) {
						codepoint = (charCode - 55296 << 10) + 65536 | nextCharCode - 56320;
						wasSurrogatePair = true;
					}
				}
			}
			if (codepoint <= 127) result += 1;
			else if (codepoint <= 2047) result += 2;
			else if (codepoint <= 65535) result += 3;
			else result += 4;
			if (wasSurrogatePair) i$2++;
		}
		return result;
	}
	createString(onigBinding2) {
		const result = onigBinding2.omalloc(this.utf8Length);
		onigBinding2.HEAPU8.set(this.utf8Value, result);
		return result;
	}
};
const _OnigString = class _OnigString$1 {
	constructor(str) {
		__publicField(this, "id", ++_OnigString$1.LAST_ID);
		__publicField(this, "_onigBinding");
		__publicField(this, "content");
		__publicField(this, "utf16Length");
		__publicField(this, "utf8Length");
		__publicField(this, "utf16OffsetToUtf8");
		__publicField(this, "utf8OffsetToUtf16");
		__publicField(this, "ptr");
		if (!onigBinding) throw new ShikiError("Must invoke loadWasm first.");
		this._onigBinding = onigBinding;
		this.content = str;
		const utfString = new UtfString(str);
		this.utf16Length = utfString.utf16Length;
		this.utf8Length = utfString.utf8Length;
		this.utf16OffsetToUtf8 = utfString.utf16OffsetToUtf8;
		this.utf8OffsetToUtf16 = utfString.utf8OffsetToUtf16;
		if (this.utf8Length < 1e4 && !_OnigString$1._sharedPtrInUse) {
			if (!_OnigString$1._sharedPtr) _OnigString$1._sharedPtr = onigBinding.omalloc(1e4);
			_OnigString$1._sharedPtrInUse = true;
			onigBinding.HEAPU8.set(utfString.utf8Value, _OnigString$1._sharedPtr);
			this.ptr = _OnigString$1._sharedPtr;
		} else {
			this.ptr = utfString.createString(onigBinding);
		}
	}
	convertUtf8OffsetToUtf16(utf8Offset) {
		if (this.utf8OffsetToUtf16) {
			if (utf8Offset < 0) return 0;
			if (utf8Offset > this.utf8Length) return this.utf16Length;
			return this.utf8OffsetToUtf16[utf8Offset];
		}
		return utf8Offset;
	}
	convertUtf16OffsetToUtf8(utf16Offset) {
		if (this.utf16OffsetToUtf8) {
			if (utf16Offset < 0) return 0;
			if (utf16Offset > this.utf16Length) return this.utf8Length;
			return this.utf16OffsetToUtf8[utf16Offset];
		}
		return utf16Offset;
	}
	dispose() {
		if (this.ptr === _OnigString$1._sharedPtr) _OnigString$1._sharedPtrInUse = false;
		else this._onigBinding.ofree(this.ptr);
	}
};
__publicField(_OnigString, "LAST_ID", 0);
__publicField(_OnigString, "_sharedPtr", 0);
__publicField(_OnigString, "_sharedPtrInUse", false);
let OnigString = _OnigString;
var OnigScanner = class {
	constructor(patterns) {
		__publicField(this, "_onigBinding");
		__publicField(this, "_ptr");
		if (!onigBinding) throw new ShikiError("Must invoke loadWasm first.");
		const strPtrsArr = [];
		const strLenArr = [];
		for (let i$2 = 0, len = patterns.length; i$2 < len; i$2++) {
			const utfString = new UtfString(patterns[i$2]);
			strPtrsArr[i$2] = utfString.createString(onigBinding);
			strLenArr[i$2] = utfString.utf8Length;
		}
		const strPtrsPtr = onigBinding.omalloc(4 * patterns.length);
		onigBinding.HEAPU32.set(strPtrsArr, strPtrsPtr / 4);
		const strLenPtr = onigBinding.omalloc(4 * patterns.length);
		onigBinding.HEAPU32.set(strLenArr, strLenPtr / 4);
		const scannerPtr = onigBinding.createOnigScanner(strPtrsPtr, strLenPtr, patterns.length);
		for (let i$2 = 0, len = patterns.length; i$2 < len; i$2++) onigBinding.ofree(strPtrsArr[i$2]);
		onigBinding.ofree(strLenPtr);
		onigBinding.ofree(strPtrsPtr);
		if (scannerPtr === 0) throwLastOnigError(onigBinding);
		this._onigBinding = onigBinding;
		this._ptr = scannerPtr;
	}
	dispose() {
		this._onigBinding.freeOnigScanner(this._ptr);
	}
	findNextMatchSync(string, startPosition, arg) {
		let options = 0;
		if (typeof arg === "number") {
			options = arg;
		}
		if (typeof string === "string") {
			string = new OnigString(string);
			const result = this._findNextMatchSync(string, startPosition, false, options);
			string.dispose();
			return result;
		}
		return this._findNextMatchSync(string, startPosition, false, options);
	}
	_findNextMatchSync(string, startPosition, debugCall, options) {
		const onigBinding2 = this._onigBinding;
		const resultPtr = onigBinding2.findNextOnigScannerMatch(this._ptr, string.id, string.ptr, string.utf8Length, string.convertUtf16OffsetToUtf8(startPosition), options);
		if (resultPtr === 0) {
			return null;
		}
		const HEAPU32 = onigBinding2.HEAPU32;
		let offset = resultPtr / 4;
		const index = HEAPU32[offset++];
		const count = HEAPU32[offset++];
		const captureIndices = [];
		for (let i$2 = 0; i$2 < count; i$2++) {
			const beg = string.convertUtf8OffsetToUtf16(HEAPU32[offset++]);
			const end = string.convertUtf8OffsetToUtf16(HEAPU32[offset++]);
			captureIndices[i$2] = {
				start: beg,
				end,
				length: end - beg
			};
		}
		return {
			index,
			captureIndices
		};
	}
};
function isInstantiatorOptionsObject(dataOrOptions) {
	return typeof dataOrOptions.instantiator === "function";
}
function isInstantiatorModule(dataOrOptions) {
	return typeof dataOrOptions.default === "function";
}
function isDataOptionsObject(dataOrOptions) {
	return typeof dataOrOptions.data !== "undefined";
}
function isResponse(dataOrOptions) {
	return typeof Response !== "undefined" && dataOrOptions instanceof Response;
}
function isArrayBuffer(data) {
	return typeof ArrayBuffer !== "undefined" && (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) || typeof Buffer !== "undefined" && Buffer.isBuffer?.(data) || typeof SharedArrayBuffer !== "undefined" && data instanceof SharedArrayBuffer || typeof Uint32Array !== "undefined" && data instanceof Uint32Array;
}
let initPromise;
function loadWasm(options) {
	if (initPromise) return initPromise;
	async function _load() {
		onigBinding = await main(async (info) => {
			let instance = options;
			instance = await instance;
			if (typeof instance === "function") instance = await instance(info);
			if (typeof instance === "function") instance = await instance(info);
			if (isInstantiatorOptionsObject(instance)) {
				instance = await instance.instantiator(info);
			} else if (isInstantiatorModule(instance)) {
				instance = await instance.default(info);
			} else {
				if (isDataOptionsObject(instance)) instance = instance.data;
				if (isResponse(instance)) {
					if (typeof WebAssembly.instantiateStreaming === "function") instance = await _makeResponseStreamingLoader(instance)(info);
					else instance = await _makeResponseNonStreamingLoader(instance)(info);
				} else if (isArrayBuffer(instance)) {
					instance = await _makeArrayBufferLoader(instance)(info);
				} else if (instance instanceof WebAssembly.Module) {
					instance = await _makeArrayBufferLoader(instance)(info);
				} else if ("default" in instance && instance.default instanceof WebAssembly.Module) {
					instance = await _makeArrayBufferLoader(instance.default)(info);
				}
			}
			if ("instance" in instance) instance = instance.instance;
			if ("exports" in instance) instance = instance.exports;
			return instance;
		});
	}
	initPromise = _load();
	return initPromise;
}
function _makeArrayBufferLoader(data) {
	return (importObject) => WebAssembly.instantiate(data, importObject);
}
function _makeResponseStreamingLoader(data) {
	return (importObject) => WebAssembly.instantiateStreaming(data, importObject);
}
function _makeResponseNonStreamingLoader(data) {
	return async (importObject) => {
		const arrayBuffer = await data.arrayBuffer();
		return WebAssembly.instantiate(arrayBuffer, importObject);
	};
}
let _defaultWasmLoader;
function setDefaultWasmLoader(_loader) {
	_defaultWasmLoader = _loader;
}
function getDefaultWasmLoader() {
	return _defaultWasmLoader;
}
async function createOnigurumaEngine(options) {
	if (options) await loadWasm(options);
	return {
		createScanner(patterns) {
			return new OnigScanner(patterns.map((p$1) => typeof p$1 === "string" ? p$1 : p$1.source));
		},
		createString(s$1) {
			return new OnigString(s$1);
		}
	};
}

//#endregion
//#region ../../node_modules/.bun/shiki@4.0.2/node_modules/shiki/dist/engine-oniguruma.mjs
var engine_oniguruma_exports = /* @__PURE__ */ __exportAll({});
__reExport(engine_oniguruma_exports, dist_exports);

//#endregion
//#region src/constants.ts
const DIFFS_TAG_NAME = "diffs-container";
const DIFFS_DEVELOPMENT_BUILD = (() => {
	try {
		return process.env.NODE_ENV === "development";
	} catch {
		return false;
	}
})();
const COMMIT_METADATA_SPLIT = /(?=^From [a-f0-9]+ .+$)/m;
const GIT_DIFF_FILE_BREAK_REGEX = /(?=^diff --git)/gm;
const UNIFIED_DIFF_FILE_BREAK_REGEX = /(?=^---\s+\S)/gm;
const FILE_CONTEXT_BLOB = /(?=^@@ )/gm;
const HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: (.*))?/m;
const SPLIT_WITH_NEWLINES = /(?<=\n)/;
const FILENAME_HEADER_REGEX = /^(---|\+\+\+)\s+([^\t\r\n]+)/;
const FILENAME_HEADER_REGEX_GIT = /^(---|\+\+\+)\s+[ab]\/([^\t\r\n]+)/;
const ALTERNATE_FILE_NAMES_GIT = /^diff --git (?:"a\/(.+?)"|a\/(.+?)) (?:"b\/(.+?)"|b\/(.+?))$/;
const INDEX_LINE_METADATA = /^index ([0-9a-f]+)\.\.([0-9a-f]+)(?: (\d+))?$/i;
const MERGE_CONFLICT_START_MARKER_REGEX = /^<{7,}(?:\s.*)?$/;
const MERGE_CONFLICT_BASE_MARKER_REGEX = /^\|{7,}(?:\s.*)?$/;
const MERGE_CONFLICT_SEPARATOR_MARKER_REGEX = /^={7,}$/;
const MERGE_CONFLICT_END_MARKER_REGEX = /^>{7,}(?:\s.*)?$/;
const HEADER_PREFIX_SLOT_ID = "header-prefix";
const HEADER_METADATA_SLOT_ID = "header-metadata";
const CUSTOM_HEADER_SLOT_ID = "header-custom";
const DEFAULT_THEMES = {
	dark: "pierre-dark",
	light: "pierre-light"
};
const THEME_CSS_ATTRIBUTE = "data-theme-css";
const UNSAFE_CSS_ATTRIBUTE = "data-unsafe-css";
const CORE_CSS_ATTRIBUTE = "data-core-css";
const DIFFS_SCROLLBAR_MEASURE_ATTRIBUTE = "data-diffs-scrollbar-measure";
const DIFFS_SCROLLBAR_GUTTER_MEASURED_PROPERTY = "--diffs-scrollbar-gutter-measured";
const DEFAULT_COLLAPSED_CONTEXT_THRESHOLD = 1;
const DEFAULT_TOKENIZE_MAX_LENGTH = 1e5;
const DEFAULT_VIRTUAL_FILE_METRICS = {
	hunkLineCount: 50,
	lineHeight: 20,
	diffHeaderHeight: 44,
	spacing: 8
};
const DEFAULT_CODE_VIEW_FILE_METRICS = {
	...DEFAULT_VIRTUAL_FILE_METRICS,
	hunkLineCount: 1
};
const DEFAULT_CODE_VIEW_LAYOUT = {
	paddingTop: 8,
	paddingBottom: 8,
	gap: 8
};
const DEFAULT_SMOOTH_SCROLL_SETTINGS = {
	omega: .015,
	positionEpsilon: .5,
	velocityEpsilon: .05
};
const DEFAULT_EXPANDED_REGION = Object.freeze({
	fromStart: 0,
	fromEnd: 0
});
const DEFAULT_RENDER_RANGE = {
	startingLine: 0,
	totalLines: Infinity,
	bufferBefore: 0,
	bufferAfter: 0
};
const EMPTY_RENDER_RANGE = {
	startingLine: 0,
	totalLines: 0,
	bufferBefore: 0,
	bufferAfter: 0
};

//#endregion
//#region src/highlighter/languages/constants.ts
const ResolvedLanguages = new Map();
const ResolvingLanguages = new Map();
const RegisteredCustomLanguages = new Map();
const AttachedLanguages = new Set();

//#endregion
//#region src/highlighter/languages/attachResolvedLanguages.ts
function attachResolvedLanguages(resolvedLanguages, highlighter$1) {
	resolvedLanguages = Array.isArray(resolvedLanguages) ? resolvedLanguages : [resolvedLanguages];
	for (const resolvedLang of resolvedLanguages) {
		if (AttachedLanguages.has(resolvedLang.name)) continue;
		let lang = ResolvedLanguages.get(resolvedLang.name);
		if (lang == null) {
			lang = resolvedLang;
			ResolvedLanguages.set(resolvedLang.name, lang);
		}
		AttachedLanguages.add(lang.name);
		highlighter$1.loadLanguageSync(lang.data);
	}
}

//#endregion
//#region src/highlighter/themes/constants.ts
const ResolvedThemes = new Map();
const ResolvingThemes = new Map();
const RegisteredCustomThemes = new Map();
const AttachedThemes = new Set();

//#endregion
//#region src/highlighter/themes/attachResolvedThemes.ts
function attachResolvedThemes(themes, highlighter$1) {
	themes = Array.isArray(themes) ? themes : [themes];
	for (let themeRef of themes) {
		let resolvedTheme;
		if (typeof themeRef === "string") {
			resolvedTheme = ResolvedThemes.get(themeRef);
			if (resolvedTheme == null) {
				throw new Error(`loadResolvedThemes: ${themeRef} is not resolved, you must resolve it before calling loadResolvedThemes`);
			}
		} else {
			resolvedTheme = themeRef;
			themeRef = themeRef.name;
			if (!ResolvedThemes.has(themeRef)) {
				ResolvedThemes.set(themeRef, resolvedTheme);
			}
		}
		if (AttachedThemes.has(themeRef)) continue;
		AttachedThemes.add(themeRef);
		highlighter$1.loadThemeSync(resolvedTheme);
	}
}

//#endregion
//#region src/utils/getFiletypeFromFileName.ts
const CUSTOM_EXTENSION_TO_FILE_FORMAT = new Map();
let customExtensionsVersion = 0;
const EXTENSION_TO_FILE_FORMAT = {
	"1c": "1c",
	abap: "abap",
	as: "actionscript-3",
	ada: "ada",
	adb: "ada",
	ads: "ada",
	adoc: "asciidoc",
	asciidoc: "asciidoc",
	"component.html": "angular-html",
	"component.ts": "angular-ts",
	conf: "nginx",
	htaccess: "apache",
	cls: "tex",
	trigger: "apex",
	apl: "apl",
	applescript: "applescript",
	scpt: "applescript",
	ara: "ara",
	asm: "asm",
	s: "riscv",
	astro: "astro",
	awk: "awk",
	bal: "ballerina",
	sh: "zsh",
	bash: "zsh",
	bat: "cmd",
	cmd: "cmd",
	be: "berry",
	beancount: "beancount",
	bib: "bibtex",
	bicep: "bicep",
	"blade.php": "blade",
	bsl: "bsl",
	c: "c",
	h: "objective-cpp",
	cs: "csharp",
	cpp: "cpp",
	hpp: "cpp",
	cc: "cpp",
	cxx: "cpp",
	hh: "cpp",
	cdc: "cdc",
	cairo: "cairo",
	clar: "clarity",
	clj: "clojure",
	cljs: "clojure",
	cljc: "clojure",
	soy: "soy",
	cmake: "cmake",
	"CMakeLists.txt": "cmake",
	cob: "cobol",
	cbl: "cobol",
	cobol: "cobol",
	CODEOWNERS: "codeowners",
	ql: "ql",
	coffee: "coffeescript",
	lisp: "lisp",
	cl: "lisp",
	lsp: "lisp",
	log: "log",
	v: "verilog",
	cql: "cql",
	cr: "crystal",
	css: "css",
	csv: "csv",
	cue: "cue",
	cypher: "cypher",
	cyp: "cypher",
	d: "d",
	dart: "dart",
	dax: "dax",
	desktop: "desktop",
	diff: "diff",
	patch: "diff",
	Dockerfile: "dockerfile",
	dockerfile: "dockerfile",
	env: "dotenv",
	dm: "dream-maker",
	edge: "edge",
	el: "emacs-lisp",
	ex: "elixir",
	exs: "elixir",
	elm: "elm",
	erb: "erb",
	erl: "erlang",
	hrl: "erlang",
	f: "fortran-fixed-form",
	for: "fortran-fixed-form",
	fs: "fsharp",
	fsi: "fsharp",
	fsx: "fsharp",
	f03: "f03",
	f08: "f08",
	f18: "f18",
	f77: "f77",
	f90: "fortran-free-form",
	f95: "fortran-free-form",
	fnl: "fennel",
	fish: "fish",
	ftl: "ftl",
	tres: "gdresource",
	res: "gdresource",
	gd: "gdscript",
	gdshader: "gdshader",
	gs: "genie",
	feature: "gherkin",
	COMMIT_EDITMSG: "git-commit",
	"git-rebase-todo": "git-rebase",
	gjs: "glimmer-js",
	gleam: "gleam",
	gts: "glimmer-ts",
	glsl: "glsl",
	vert: "glsl",
	frag: "glsl",
	shader: "shaderlab",
	gp: "gnuplot",
	plt: "gnuplot",
	gnuplot: "gnuplot",
	go: "go",
	graphql: "graphql",
	gql: "graphql",
	groovy: "groovy",
	gvy: "groovy",
	hack: "hack",
	haml: "haml",
	hbs: "handlebars",
	handlebars: "handlebars",
	hs: "haskell",
	lhs: "haskell",
	hx: "haxe",
	hcl: "hcl",
	hjson: "hjson",
	hlsl: "hlsl",
	fx: "hlsl",
	html: "html",
	htm: "html",
	http: "http",
	rest: "http",
	hxml: "hxml",
	hy: "hy",
	imba: "imba",
	ini: "ini",
	cfg: "ini",
	jade: "pug",
	pug: "pug",
	java: "java",
	js: "javascript",
	mjs: "javascript",
	cjs: "javascript",
	jinja: "jinja",
	jinja2: "jinja",
	j2: "jinja",
	jison: "jison",
	jl: "julia",
	json: "json",
	json5: "json5",
	jsonc: "jsonc",
	jsonl: "jsonl",
	jsonnet: "jsonnet",
	libsonnet: "jsonnet",
	jssm: "jssm",
	jsx: "jsx",
	kt: "kotlin",
	kts: "kts",
	kql: "kusto",
	tex: "tex",
	ltx: "tex",
	lean: "lean4",
	less: "less",
	liquid: "liquid",
	lit: "lit",
	ll: "llvm",
	logo: "logo",
	lua: "lua",
	luau: "luau",
	Makefile: "makefile",
	mk: "makefile",
	makefile: "makefile",
	md: "markdown",
	markdown: "markdown",
	marko: "marko",
	m: "wolfram",
	mat: "matlab",
	mdc: "mdc",
	mdx: "mdx",
	wiki: "wikitext",
	mediawiki: "wikitext",
	mmd: "mermaid",
	mermaid: "mermaid",
	mips: "mipsasm",
	mojo: "mojo",
	"🔥": "mojo",
	move: "move",
	nar: "narrat",
	nf: "nextflow",
	nim: "nim",
	nims: "nim",
	nimble: "nim",
	nix: "nix",
	nu: "nushell",
	mm: "objective-cpp",
	ml: "ocaml",
	mli: "ocaml",
	mll: "ocaml",
	mly: "ocaml",
	pas: "pascal",
	p: "pascal",
	pl: "prolog",
	pm: "perl",
	t: "perl",
	raku: "raku",
	p6: "raku",
	pl6: "raku",
	php: "php",
	phtml: "php",
	pls: "plsql",
	sql: "sql",
	po: "po",
	polar: "polar",
	pcss: "postcss",
	pot: "pot",
	potx: "potx",
	pq: "powerquery",
	pqm: "powerquery",
	ps1: "powershell",
	psm1: "powershell",
	psd1: "powershell",
	prisma: "prisma",
	pro: "prolog",
	P: "prolog",
	properties: "properties",
	proto: "protobuf",
	pp: "puppet",
	purs: "purescript",
	py: "python",
	pyw: "python",
	pyi: "python",
	qml: "qml",
	qmldir: "qmldir",
	qss: "qss",
	r: "r",
	R: "r",
	rkt: "racket",
	rktl: "racket",
	razor: "razor",
	cshtml: "razor",
	rb: "ruby",
	rbw: "ruby",
	reg: "reg",
	regex: "regexp",
	rel: "rel",
	rs: "rust",
	rst: "rst",
	rake: "ruby",
	gemspec: "ruby",
	jbuilder: "ruby",
	builder: "ruby",
	rabl: "ruby",
	arb: "ruby",
	ru: "ruby",
	podspec: "ruby",
	Gemfile: "ruby",
	Rakefile: "ruby",
	Guardfile: "ruby",
	Capfile: "ruby",
	Berksfile: "ruby",
	Brewfile: "ruby",
	Vagrantfile: "ruby",
	Thorfile: "ruby",
	Appraisals: "ruby",
	Dangerfile: "ruby",
	sas: "sas",
	sass: "sass",
	scala: "scala",
	sc: "scala",
	scm: "scheme",
	ss: "scheme",
	sld: "scheme",
	scss: "scss",
	sdbl: "sdbl",
	shadergraph: "shader",
	st: "smalltalk",
	sol: "solidity",
	sparql: "sparql",
	rq: "sparql",
	spl: "splunk",
	config: "ssh-config",
	do: "stata",
	ado: "stata",
	dta: "stata",
	styl: "stylus",
	stylus: "stylus",
	svelte: "svelte",
	swift: "swift",
	sv: "system-verilog",
	svh: "system-verilog",
	service: "systemd",
	socket: "systemd",
	device: "systemd",
	timer: "systemd",
	talon: "talonscript",
	tasl: "tasl",
	tcl: "tcl",
	templ: "templ",
	tf: "tf",
	tfvars: "tfvars",
	toml: "toml",
	ts: "typescript",
	tsp: "typespec",
	tsv: "tsv",
	tsx: "tsx",
	ttl: "turtle",
	twig: "twig",
	typ: "typst",
	vv: "v",
	vala: "vala",
	vapi: "vala",
	vb: "vb",
	vbs: "vb",
	bas: "vb",
	vh: "verilog",
	vhd: "vhdl",
	vhdl: "vhdl",
	vim: "vimscript",
	vue: "vue",
	"vine.ts": "vue-vine",
	vy: "vyper",
	wasm: "wasm",
	wat: "wasm",
	wy: "文言",
	wgsl: "wgsl",
	wit: "wit",
	wl: "wolfram",
	nb: "wolfram",
	xml: "xml",
	xsl: "xsl",
	xslt: "xsl",
	yaml: "yaml",
	yml: "yml",
	zs: "zenscript",
	zig: "zig",
	zsh: "zsh",
	sty: "tex"
};
function getFiletypeFromFileName(fileName) {
	if (CUSTOM_EXTENSION_TO_FILE_FORMAT.has(fileName)) {
		return CUSTOM_EXTENSION_TO_FILE_FORMAT.get(fileName) ?? "text";
	}
	if (EXTENSION_TO_FILE_FORMAT[fileName] != null) {
		return EXTENSION_TO_FILE_FORMAT[fileName];
	}
	const compoundMatch = fileName.match(/\.([^/\\]+\.[^/\\]+)$/);
	if (compoundMatch != null) {
		if (CUSTOM_EXTENSION_TO_FILE_FORMAT.has(compoundMatch[1])) {
			return CUSTOM_EXTENSION_TO_FILE_FORMAT.get(compoundMatch[1]) ?? "text";
		}
		if (EXTENSION_TO_FILE_FORMAT[compoundMatch[1]] != null) {
			return EXTENSION_TO_FILE_FORMAT[compoundMatch[1]] ?? "text";
		}
	}
	const simpleMatch = fileName.match(/\.([^.]+)$/)?.[1] ?? "";
	if (CUSTOM_EXTENSION_TO_FILE_FORMAT.has(simpleMatch)) {
		return CUSTOM_EXTENSION_TO_FILE_FORMAT.get(simpleMatch) ?? "text";
	}
	return EXTENSION_TO_FILE_FORMAT[simpleMatch] ?? "text";
}
function replaceCustomExtensions(version, map) {
	if (version <= customExtensionsVersion) {
		return false;
	}
	CUSTOM_EXTENSION_TO_FILE_FORMAT.clear();
	for (const key$1 in map) {
		const lang = map[key$1];
		if (lang != null) {
			CUSTOM_EXTENSION_TO_FILE_FORMAT.set(key$1, lang);
		}
	}
	customExtensionsVersion = version;
	return true;
}
function getCustomExtensionsVersion() {
	return customExtensionsVersion;
}
function setCustomExtension(key$1, lang) {
	const existing = CUSTOM_EXTENSION_TO_FILE_FORMAT.get(key$1);
	if (existing === lang) {
		return false;
	}
	if (existing != null) {
		console.warn(`setCustomExtension: overriding custom mapping for "${key$1}" from "${existing}" to "${lang}"`);
	}
	CUSTOM_EXTENSION_TO_FILE_FORMAT.set(key$1, lang);
	customExtensionsVersion++;
	return true;
}
function getCustomExtensionsMap() {
	return Object.fromEntries(CUSTOM_EXTENSION_TO_FILE_FORMAT);
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/diff/base.js
var Diff = class {
	diff(oldStr, newStr, options = {}) {
		let callback;
		if (typeof options === "function") {
			callback = options;
			options = {};
		} else if ("callback" in options) {
			callback = options.callback;
		}
		const oldString = this.castInput(oldStr, options);
		const newString = this.castInput(newStr, options);
		const oldTokens = this.removeEmpty(this.tokenize(oldString, options));
		const newTokens = this.removeEmpty(this.tokenize(newString, options));
		return this.diffWithOptionsObj(oldTokens, newTokens, options, callback);
	}
	diffWithOptionsObj(oldTokens, newTokens, options, callback) {
		var _a;
		const done = (value) => {
			value = this.postProcess(value, options);
			if (callback) {
				setTimeout(function() {
					callback(value);
				}, 0);
				return undefined;
			} else {
				return value;
			}
		};
		const newLen = newTokens.length, oldLen = oldTokens.length;
		let editLength = 1;
		let maxEditLength = newLen + oldLen;
		if (options.maxEditLength != null) {
			maxEditLength = Math.min(maxEditLength, options.maxEditLength);
		}
		const maxExecutionTime = (_a = options.timeout) !== null && _a !== void 0 ? _a : Infinity;
		const abortAfterTimestamp = Date.now() + maxExecutionTime;
		const bestPath = [{
			oldPos: -1,
			lastComponent: undefined
		}];
		let newPos = this.extractCommon(bestPath[0], newTokens, oldTokens, 0, options);
		if (bestPath[0].oldPos + 1 >= oldLen && newPos + 1 >= newLen) {
			return done(this.buildValues(bestPath[0].lastComponent, newTokens, oldTokens));
		}
		let minDiagonalToConsider = -Infinity, maxDiagonalToConsider = Infinity;
		const execEditLength = () => {
			for (let diagonalPath = Math.max(minDiagonalToConsider, -editLength); diagonalPath <= Math.min(maxDiagonalToConsider, editLength); diagonalPath += 2) {
				let basePath;
				const removePath = bestPath[diagonalPath - 1], addPath = bestPath[diagonalPath + 1];
				if (removePath) {
					bestPath[diagonalPath - 1] = undefined;
				}
				let canAdd = false;
				if (addPath) {
					const addPathNewPos = addPath.oldPos - diagonalPath;
					canAdd = addPath && 0 <= addPathNewPos && addPathNewPos < newLen;
				}
				const canRemove = removePath && removePath.oldPos + 1 < oldLen;
				if (!canAdd && !canRemove) {
					bestPath[diagonalPath] = undefined;
					continue;
				}
				if (!canRemove || canAdd && removePath.oldPos < addPath.oldPos) {
					basePath = this.addToPath(addPath, true, false, 0, options);
				} else {
					basePath = this.addToPath(removePath, false, true, 1, options);
				}
				newPos = this.extractCommon(basePath, newTokens, oldTokens, diagonalPath, options);
				if (basePath.oldPos + 1 >= oldLen && newPos + 1 >= newLen) {
					return done(this.buildValues(basePath.lastComponent, newTokens, oldTokens)) || true;
				} else {
					bestPath[diagonalPath] = basePath;
					if (basePath.oldPos + 1 >= oldLen) {
						maxDiagonalToConsider = Math.min(maxDiagonalToConsider, diagonalPath - 1);
					}
					if (newPos + 1 >= newLen) {
						minDiagonalToConsider = Math.max(minDiagonalToConsider, diagonalPath + 1);
					}
				}
			}
			editLength++;
		};
		if (callback) {
			(function exec() {
				setTimeout(function() {
					if (editLength > maxEditLength || Date.now() > abortAfterTimestamp) {
						return callback(undefined);
					}
					if (!execEditLength()) {
						exec();
					}
				}, 0);
			})();
		} else {
			while (editLength <= maxEditLength && Date.now() <= abortAfterTimestamp) {
				const ret = execEditLength();
				if (ret) {
					return ret;
				}
			}
		}
	}
	addToPath(path, added, removed, oldPosInc, options) {
		const last = path.lastComponent;
		if (last && !options.oneChangePerToken && last.added === added && last.removed === removed) {
			return {
				oldPos: path.oldPos + oldPosInc,
				lastComponent: {
					count: last.count + 1,
					added,
					removed,
					previousComponent: last.previousComponent
				}
			};
		} else {
			return {
				oldPos: path.oldPos + oldPosInc,
				lastComponent: {
					count: 1,
					added,
					removed,
					previousComponent: last
				}
			};
		}
	}
	extractCommon(basePath, newTokens, oldTokens, diagonalPath, options) {
		const newLen = newTokens.length, oldLen = oldTokens.length;
		let oldPos = basePath.oldPos, newPos = oldPos - diagonalPath, commonCount = 0;
		while (newPos + 1 < newLen && oldPos + 1 < oldLen && this.equals(oldTokens[oldPos + 1], newTokens[newPos + 1], options)) {
			newPos++;
			oldPos++;
			commonCount++;
			if (options.oneChangePerToken) {
				basePath.lastComponent = {
					count: 1,
					previousComponent: basePath.lastComponent,
					added: false,
					removed: false
				};
			}
		}
		if (commonCount && !options.oneChangePerToken) {
			basePath.lastComponent = {
				count: commonCount,
				previousComponent: basePath.lastComponent,
				added: false,
				removed: false
			};
		}
		basePath.oldPos = oldPos;
		return newPos;
	}
	equals(left, right, options) {
		if (options.comparator) {
			return options.comparator(left, right);
		} else {
			return left === right || !!options.ignoreCase && left.toLowerCase() === right.toLowerCase();
		}
	}
	removeEmpty(array) {
		const ret = [];
		for (let i$2 = 0; i$2 < array.length; i$2++) {
			if (array[i$2]) {
				ret.push(array[i$2]);
			}
		}
		return ret;
	}
	castInput(value, options) {
		return value;
	}
	tokenize(value, options) {
		return Array.from(value);
	}
	join(chars) {
		return chars.join("");
	}
	postProcess(changeObjects, options) {
		return changeObjects;
	}
	get useLongestToken() {
		return false;
	}
	buildValues(lastComponent, newTokens, oldTokens) {
		const components = [];
		let nextComponent;
		while (lastComponent) {
			components.push(lastComponent);
			nextComponent = lastComponent.previousComponent;
			delete lastComponent.previousComponent;
			lastComponent = nextComponent;
		}
		components.reverse();
		const componentLen = components.length;
		let componentPos = 0, newPos = 0, oldPos = 0;
		for (; componentPos < componentLen; componentPos++) {
			const component = components[componentPos];
			if (!component.removed) {
				if (!component.added && this.useLongestToken) {
					let value = newTokens.slice(newPos, newPos + component.count);
					value = value.map(function(value$1, i$2) {
						const oldValue = oldTokens[oldPos + i$2];
						return oldValue.length > value$1.length ? oldValue : value$1;
					});
					component.value = this.join(value);
				} else {
					component.value = this.join(newTokens.slice(newPos, newPos + component.count));
				}
				newPos += component.count;
				if (!component.added) {
					oldPos += component.count;
				}
			} else {
				component.value = this.join(oldTokens.slice(oldPos, oldPos + component.count));
				oldPos += component.count;
			}
		}
		return components;
	}
};

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/diff/character.js
var CharacterDiff = class extends Diff {};
const characterDiff = new CharacterDiff();
function diffChars(oldStr, newStr, options) {
	return characterDiff.diff(oldStr, newStr, options);
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/util/string.js
function longestCommonPrefix(str1, str2) {
	let i$2;
	for (i$2 = 0; i$2 < str1.length && i$2 < str2.length; i$2++) {
		if (str1[i$2] != str2[i$2]) {
			return str1.slice(0, i$2);
		}
	}
	return str1.slice(0, i$2);
}
function longestCommonSuffix(str1, str2) {
	let i$2;
	if (!str1 || !str2 || str1[str1.length - 1] != str2[str2.length - 1]) {
		return "";
	}
	for (i$2 = 0; i$2 < str1.length && i$2 < str2.length; i$2++) {
		if (str1[str1.length - (i$2 + 1)] != str2[str2.length - (i$2 + 1)]) {
			return str1.slice(-i$2);
		}
	}
	return str1.slice(-i$2);
}
function replacePrefix(string, oldPrefix, newPrefix) {
	if (string.slice(0, oldPrefix.length) != oldPrefix) {
		throw Error(`string ${JSON.stringify(string)} doesn't start with prefix ${JSON.stringify(oldPrefix)}; this is a bug`);
	}
	return newPrefix + string.slice(oldPrefix.length);
}
function replaceSuffix(string, oldSuffix, newSuffix) {
	if (!oldSuffix) {
		return string + newSuffix;
	}
	if (string.slice(-oldSuffix.length) != oldSuffix) {
		throw Error(`string ${JSON.stringify(string)} doesn't end with suffix ${JSON.stringify(oldSuffix)}; this is a bug`);
	}
	return string.slice(0, -oldSuffix.length) + newSuffix;
}
function removePrefix(string, oldPrefix) {
	return replacePrefix(string, oldPrefix, "");
}
function removeSuffix(string, oldSuffix) {
	return replaceSuffix(string, oldSuffix, "");
}
function maximumOverlap(string1, string2) {
	return string2.slice(0, overlapCount(string1, string2));
}
function overlapCount(a$1, b$2) {
	let startA = 0;
	if (a$1.length > b$2.length) {
		startA = a$1.length - b$2.length;
	}
	let endB = b$2.length;
	if (a$1.length < b$2.length) {
		endB = a$1.length;
	}
	const map = Array(endB);
	let k$2 = 0;
	map[0] = 0;
	for (let j$1 = 1; j$1 < endB; j$1++) {
		if (b$2[j$1] == b$2[k$2]) {
			map[j$1] = map[k$2];
		} else {
			map[j$1] = k$2;
		}
		while (k$2 > 0 && b$2[j$1] != b$2[k$2]) {
			k$2 = map[k$2];
		}
		if (b$2[j$1] == b$2[k$2]) {
			k$2++;
		}
	}
	k$2 = 0;
	for (let i$2 = startA; i$2 < a$1.length; i$2++) {
		while (k$2 > 0 && a$1[i$2] != b$2[k$2]) {
			k$2 = map[k$2];
		}
		if (a$1[i$2] == b$2[k$2]) {
			k$2++;
		}
	}
	return k$2;
}
/**
* Returns true if the string consistently uses Windows line endings.
*/
function hasOnlyWinLineEndings(string) {
	return string.includes("\r\n") && !string.startsWith("\n") && !string.match(/[^\r]\n/);
}
/**
* Returns true if the string consistently uses Unix line endings.
*/
function hasOnlyUnixLineEndings(string) {
	return !string.includes("\r\n") && string.includes("\n");
}
function trailingWs(string) {
	let i$2;
	for (i$2 = string.length - 1; i$2 >= 0; i$2--) {
		if (!string[i$2].match(/\s/)) {
			break;
		}
	}
	return string.substring(i$2 + 1);
}
function leadingWs(string) {
	const match = string.match(/^\s*/);
	return match ? match[0] : "";
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/diff/word.js
const extendedWordChars = "a-zA-Z0-9_\\u{AD}\\u{C0}-\\u{D6}\\u{D8}-\\u{F6}\\u{F8}-\\u{2C6}\\u{2C8}-\\u{2D7}\\u{2DE}-\\u{2FF}\\u{1E00}-\\u{1EFF}";
const tokenizeIncludingWhitespace = new RegExp(`[${extendedWordChars}]+|\\s+|[^${extendedWordChars}]`, "ug");
var WordDiff = class extends Diff {
	equals(left, right, options) {
		if (options.ignoreCase) {
			left = left.toLowerCase();
			right = right.toLowerCase();
		}
		return left.trim() === right.trim();
	}
	tokenize(value, options = {}) {
		let parts;
		if (options.intlSegmenter) {
			const segmenter = options.intlSegmenter;
			if (segmenter.resolvedOptions().granularity != "word") {
				throw new Error("The segmenter passed must have a granularity of \"word\"");
			}
			parts = [];
			for (const segmentObj of Array.from(segmenter.segment(value))) {
				const segment = segmentObj.segment;
				if (parts.length && /\s/.test(parts[parts.length - 1]) && /\s/.test(segment)) {
					parts[parts.length - 1] += segment;
				} else {
					parts.push(segment);
				}
			}
		} else {
			parts = value.match(tokenizeIncludingWhitespace) || [];
		}
		const tokens = [];
		let prevPart = null;
		parts.forEach((part) => {
			if (/\s/.test(part)) {
				if (prevPart == null) {
					tokens.push(part);
				} else {
					tokens.push(tokens.pop() + part);
				}
			} else if (prevPart != null && /\s/.test(prevPart)) {
				if (tokens[tokens.length - 1] == prevPart) {
					tokens.push(tokens.pop() + part);
				} else {
					tokens.push(prevPart + part);
				}
			} else {
				tokens.push(part);
			}
			prevPart = part;
		});
		return tokens;
	}
	join(tokens) {
		return tokens.map((token$1, i$2) => {
			if (i$2 == 0) {
				return token$1;
			} else {
				return token$1.replace(/^\s+/, "");
			}
		}).join("");
	}
	postProcess(changes, options) {
		if (!changes || options.oneChangePerToken) {
			return changes;
		}
		let lastKeep = null;
		let insertion = null;
		let deletion = null;
		changes.forEach((change) => {
			if (change.added) {
				insertion = change;
			} else if (change.removed) {
				deletion = change;
			} else {
				if (insertion || deletion) {
					dedupeWhitespaceInChangeObjects(lastKeep, deletion, insertion, change);
				}
				lastKeep = change;
				insertion = null;
				deletion = null;
			}
		});
		if (insertion || deletion) {
			dedupeWhitespaceInChangeObjects(lastKeep, deletion, insertion, null);
		}
		return changes;
	}
};
const wordDiff = new WordDiff();
function diffWords(oldStr, newStr, options) {
	if ((options === null || options === void 0 ? void 0 : options.ignoreWhitespace) != null && !options.ignoreWhitespace) {
		return diffWordsWithSpace(oldStr, newStr, options);
	}
	return wordDiff.diff(oldStr, newStr, options);
}
function dedupeWhitespaceInChangeObjects(startKeep, deletion, insertion, endKeep) {
	if (deletion && insertion) {
		const oldWsPrefix = leadingWs(deletion.value);
		const oldWsSuffix = trailingWs(deletion.value);
		const newWsPrefix = leadingWs(insertion.value);
		const newWsSuffix = trailingWs(insertion.value);
		if (startKeep) {
			const commonWsPrefix = longestCommonPrefix(oldWsPrefix, newWsPrefix);
			startKeep.value = replaceSuffix(startKeep.value, newWsPrefix, commonWsPrefix);
			deletion.value = removePrefix(deletion.value, commonWsPrefix);
			insertion.value = removePrefix(insertion.value, commonWsPrefix);
		}
		if (endKeep) {
			const commonWsSuffix = longestCommonSuffix(oldWsSuffix, newWsSuffix);
			endKeep.value = replacePrefix(endKeep.value, newWsSuffix, commonWsSuffix);
			deletion.value = removeSuffix(deletion.value, commonWsSuffix);
			insertion.value = removeSuffix(insertion.value, commonWsSuffix);
		}
	} else if (insertion) {
		if (startKeep) {
			const ws = leadingWs(insertion.value);
			insertion.value = insertion.value.substring(ws.length);
		}
		if (endKeep) {
			const ws = leadingWs(endKeep.value);
			endKeep.value = endKeep.value.substring(ws.length);
		}
	} else if (startKeep && endKeep) {
		const newWsFull = leadingWs(endKeep.value), delWsStart = leadingWs(deletion.value), delWsEnd = trailingWs(deletion.value);
		const newWsStart = longestCommonPrefix(newWsFull, delWsStart);
		deletion.value = removePrefix(deletion.value, newWsStart);
		const newWsEnd = longestCommonSuffix(removePrefix(newWsFull, newWsStart), delWsEnd);
		deletion.value = removeSuffix(deletion.value, newWsEnd);
		endKeep.value = replacePrefix(endKeep.value, newWsFull, newWsEnd);
		startKeep.value = replaceSuffix(startKeep.value, newWsFull, newWsFull.slice(0, newWsFull.length - newWsEnd.length));
	} else if (endKeep) {
		const endKeepWsPrefix = leadingWs(endKeep.value);
		const deletionWsSuffix = trailingWs(deletion.value);
		const overlap = maximumOverlap(deletionWsSuffix, endKeepWsPrefix);
		deletion.value = removeSuffix(deletion.value, overlap);
	} else if (startKeep) {
		const startKeepWsSuffix = trailingWs(startKeep.value);
		const deletionWsPrefix = leadingWs(deletion.value);
		const overlap = maximumOverlap(startKeepWsSuffix, deletionWsPrefix);
		deletion.value = removePrefix(deletion.value, overlap);
	}
}
var WordsWithSpaceDiff = class extends Diff {
	tokenize(value) {
		const regex = new RegExp(`(\\r?\\n)|[${extendedWordChars}]+|[^\\S\\n\\r]+|[^${extendedWordChars}]`, "ug");
		return value.match(regex) || [];
	}
};
const wordsWithSpaceDiff = new WordsWithSpaceDiff();
function diffWordsWithSpace(oldStr, newStr, options) {
	return wordsWithSpaceDiff.diff(oldStr, newStr, options);
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/util/params.js
function generateOptions(options, defaults) {
	if (typeof options === "function") {
		defaults.callback = options;
	} else if (options) {
		for (const name in options) {
			/* istanbul ignore else */
			if (Object.prototype.hasOwnProperty.call(options, name)) {
				defaults[name] = options[name];
			}
		}
	}
	return defaults;
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/diff/line.js
var LineDiff = class extends Diff {
	constructor() {
		super(...arguments);
		this.tokenize = tokenize;
	}
	equals(left, right, options) {
		if (options.ignoreWhitespace) {
			if (!options.newlineIsToken || !left.includes("\n")) {
				left = left.trim();
			}
			if (!options.newlineIsToken || !right.includes("\n")) {
				right = right.trim();
			}
		} else if (options.ignoreNewlineAtEof && !options.newlineIsToken) {
			if (left.endsWith("\n")) {
				left = left.slice(0, -1);
			}
			if (right.endsWith("\n")) {
				right = right.slice(0, -1);
			}
		}
		return super.equals(left, right, options);
	}
};
const lineDiff = new LineDiff();
function diffLines(oldStr, newStr, options) {
	return lineDiff.diff(oldStr, newStr, options);
}
function diffTrimmedLines(oldStr, newStr, options) {
	options = generateOptions(options, { ignoreWhitespace: true });
	return lineDiff.diff(oldStr, newStr, options);
}
function tokenize(value, options) {
	if (options.stripTrailingCr) {
		value = value.replace(/\r\n/g, "\n");
	}
	const retLines = [], linesAndNewlines = value.split(/(\n|\r\n)/);
	if (!linesAndNewlines[linesAndNewlines.length - 1]) {
		linesAndNewlines.pop();
	}
	for (let i$2 = 0; i$2 < linesAndNewlines.length; i$2++) {
		const line = linesAndNewlines[i$2];
		if (i$2 % 2 && !options.newlineIsToken) {
			retLines[retLines.length - 1] += line;
		} else {
			retLines.push(line);
		}
	}
	return retLines;
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/diff/sentence.js
function isSentenceEndPunct(char) {
	return char == "." || char == "!" || char == "?";
}
var SentenceDiff = class extends Diff {
	tokenize(value) {
		var _a;
		const result = [];
		let tokenStartI = 0;
		for (let i$2 = 0; i$2 < value.length; i$2++) {
			if (i$2 == value.length - 1) {
				result.push(value.slice(tokenStartI));
				break;
			}
			if (isSentenceEndPunct(value[i$2]) && value[i$2 + 1].match(/\s/)) {
				result.push(value.slice(tokenStartI, i$2 + 1));
				i$2 = tokenStartI = i$2 + 1;
				while ((_a = value[i$2 + 1]) === null || _a === void 0 ? void 0 : _a.match(/\s/)) {
					i$2++;
				}
				result.push(value.slice(tokenStartI, i$2 + 1));
				tokenStartI = i$2 + 1;
			}
		}
		return result;
	}
};
const sentenceDiff = new SentenceDiff();
function diffSentences(oldStr, newStr, options) {
	return sentenceDiff.diff(oldStr, newStr, options);
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/diff/css.js
var CssDiff = class extends Diff {
	tokenize(value) {
		return value.split(/([{}:;,]|\s+)/);
	}
};
const cssDiff = new CssDiff();
function diffCss(oldStr, newStr, options) {
	return cssDiff.diff(oldStr, newStr, options);
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/diff/json.js
var JsonDiff = class extends Diff {
	constructor() {
		super(...arguments);
		this.tokenize = tokenize;
	}
	get useLongestToken() {
		return true;
	}
	castInput(value, options) {
		const { undefinedReplacement, stringifyReplacer = (k$2, v$1) => typeof v$1 === "undefined" ? undefinedReplacement : v$1 } = options;
		return typeof value === "string" ? value : JSON.stringify(canonicalize(value, null, null, stringifyReplacer), null, "  ");
	}
	equals(left, right, options) {
		return super.equals(left.replace(/,([\r\n])/g, "$1"), right.replace(/,([\r\n])/g, "$1"), options);
	}
};
const jsonDiff = new JsonDiff();
function diffJson(oldStr, newStr, options) {
	return jsonDiff.diff(oldStr, newStr, options);
}
function canonicalize(obj, stack, replacementStack, replacer, key$1) {
	stack = stack || [];
	replacementStack = replacementStack || [];
	if (replacer) {
		obj = replacer(key$1 === undefined ? "" : key$1, obj);
	}
	let i$2;
	for (i$2 = 0; i$2 < stack.length; i$2 += 1) {
		if (stack[i$2] === obj) {
			return replacementStack[i$2];
		}
	}
	let canonicalizedObj;
	if ("[object Array]" === Object.prototype.toString.call(obj)) {
		stack.push(obj);
		canonicalizedObj = new Array(obj.length);
		replacementStack.push(canonicalizedObj);
		for (i$2 = 0; i$2 < obj.length; i$2 += 1) {
			canonicalizedObj[i$2] = canonicalize(obj[i$2], stack, replacementStack, replacer, String(i$2));
		}
		stack.pop();
		replacementStack.pop();
		return canonicalizedObj;
	}
	if (obj && obj.toJSON) {
		obj = obj.toJSON();
	}
	if (typeof obj === "object" && obj !== null) {
		stack.push(obj);
		canonicalizedObj = {};
		replacementStack.push(canonicalizedObj);
		const sortedKeys = [];
		let key$2;
		for (key$2 in obj) {
			/* istanbul ignore else */
			if (Object.prototype.hasOwnProperty.call(obj, key$2)) {
				sortedKeys.push(key$2);
			}
		}
		sortedKeys.sort();
		for (i$2 = 0; i$2 < sortedKeys.length; i$2 += 1) {
			key$2 = sortedKeys[i$2];
			canonicalizedObj[key$2] = canonicalize(obj[key$2], stack, replacementStack, replacer, key$2);
		}
		stack.pop();
		replacementStack.pop();
	} else {
		canonicalizedObj = obj;
	}
	return canonicalizedObj;
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/diff/array.js
var ArrayDiff = class extends Diff {
	tokenize(value) {
		return value.slice();
	}
	join(value) {
		return value;
	}
	removeEmpty(value) {
		return value;
	}
};
const arrayDiff = new ArrayDiff();
function diffArrays(oldArr, newArr, options) {
	return arrayDiff.diff(oldArr, newArr, options);
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/patch/line-endings.js
function unixToWin(patch) {
	if (Array.isArray(patch)) {
		return patch.map((p$1) => unixToWin(p$1));
	}
	return Object.assign(Object.assign({}, patch), { hunks: patch.hunks.map((hunk) => Object.assign(Object.assign({}, hunk), { lines: hunk.lines.map((line, i$2) => {
		var _a;
		return line.startsWith("\\") || line.endsWith("\r") || ((_a = hunk.lines[i$2 + 1]) === null || _a === void 0 ? void 0 : _a.startsWith("\\")) ? line : line + "\r";
	}) })) });
}
function winToUnix(patch) {
	if (Array.isArray(patch)) {
		return patch.map((p$1) => winToUnix(p$1));
	}
	return Object.assign(Object.assign({}, patch), { hunks: patch.hunks.map((hunk) => Object.assign(Object.assign({}, hunk), { lines: hunk.lines.map((line) => line.endsWith("\r") ? line.substring(0, line.length - 1) : line) })) });
}
/**
* Returns true if the patch consistently uses Unix line endings (or only involves one line and has
* no line endings).
*/
function isUnix(patch) {
	if (!Array.isArray(patch)) {
		patch = [patch];
	}
	return !patch.some((index) => index.hunks.some((hunk) => hunk.lines.some((line) => !line.startsWith("\\") && line.endsWith("\r"))));
}
/**
* Returns true if the patch uses Windows line endings and only Windows line endings.
*/
function isWin(patch) {
	if (!Array.isArray(patch)) {
		patch = [patch];
	}
	return patch.some((index) => index.hunks.some((hunk) => hunk.lines.some((line) => line.endsWith("\r")))) && patch.every((index) => index.hunks.every((hunk) => hunk.lines.every((line, i$2) => {
		var _a;
		return line.startsWith("\\") || line.endsWith("\r") || ((_a = hunk.lines[i$2 + 1]) === null || _a === void 0 ? void 0 : _a.startsWith("\\"));
	})));
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/patch/parse.js
/**
* Parses a patch into structured data, in the same structure returned by `structuredPatch`.
*
* @return a JSON object representation of the a patch, suitable for use with the `applyPatch` method.
*/
function parsePatch(uniDiff) {
	const diffstr = uniDiff.split(/\n/), list = [];
	let i$2 = 0;
	function parseIndex() {
		const index = {};
		list.push(index);
		while (i$2 < diffstr.length) {
			const line = diffstr[i$2];
			if (/^(---|\+\+\+|@@)\s/.test(line)) {
				break;
			}
			const headerMatch = /^(?:Index:|diff(?: -r \w+)+)\s+/.exec(line);
			if (headerMatch) {
				index.index = line.substring(headerMatch[0].length).trim();
			}
			i$2++;
		}
		parseFileHeader(index);
		parseFileHeader(index);
		index.hunks = [];
		while (i$2 < diffstr.length) {
			const line = diffstr[i$2];
			if (/^(Index:\s|diff\s|---\s|\+\+\+\s|===================================================================)/.test(line)) {
				break;
			} else if (/^@@/.test(line)) {
				index.hunks.push(parseHunk());
			} else if (line) {
				throw new Error("Unknown line " + (i$2 + 1) + " " + JSON.stringify(line));
			} else {
				i$2++;
			}
		}
	}
	function parseFileHeader(index) {
		const fileHeaderMatch = /^(---|\+\+\+)\s+/.exec(diffstr[i$2]);
		if (fileHeaderMatch) {
			const prefix = fileHeaderMatch[1], data = diffstr[i$2].substring(3).trim().split("	", 2), header = (data[1] || "").trim();
			let fileName = data[0].replace(/\\\\/g, "\\");
			if (fileName.startsWith("\"") && fileName.endsWith("\"")) {
				fileName = fileName.substr(1, fileName.length - 2);
			}
			if (prefix === "---") {
				index.oldFileName = fileName;
				index.oldHeader = header;
			} else {
				index.newFileName = fileName;
				index.newHeader = header;
			}
			i$2++;
		}
	}
	function parseHunk() {
		var _a;
		const chunkHeaderIndex = i$2, chunkHeaderLine = diffstr[i$2++], chunkHeader = chunkHeaderLine.split(/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
		const hunk = {
			oldStart: +chunkHeader[1],
			oldLines: typeof chunkHeader[2] === "undefined" ? 1 : +chunkHeader[2],
			newStart: +chunkHeader[3],
			newLines: typeof chunkHeader[4] === "undefined" ? 1 : +chunkHeader[4],
			lines: []
		};
		if (hunk.oldLines === 0) {
			hunk.oldStart += 1;
		}
		if (hunk.newLines === 0) {
			hunk.newStart += 1;
		}
		let addCount = 0, removeCount = 0;
		for (; i$2 < diffstr.length && (removeCount < hunk.oldLines || addCount < hunk.newLines || ((_a = diffstr[i$2]) === null || _a === void 0 ? void 0 : _a.startsWith("\\"))); i$2++) {
			const operation = diffstr[i$2].length == 0 && i$2 != diffstr.length - 1 ? " " : diffstr[i$2][0];
			if (operation === "+" || operation === "-" || operation === " " || operation === "\\") {
				hunk.lines.push(diffstr[i$2]);
				if (operation === "+") {
					addCount++;
				} else if (operation === "-") {
					removeCount++;
				} else if (operation === " ") {
					addCount++;
					removeCount++;
				}
			} else {
				throw new Error(`Hunk at line ${chunkHeaderIndex + 1} contained invalid line ${diffstr[i$2]}`);
			}
		}
		if (!addCount && hunk.newLines === 1) {
			hunk.newLines = 0;
		}
		if (!removeCount && hunk.oldLines === 1) {
			hunk.oldLines = 0;
		}
		if (addCount !== hunk.newLines) {
			throw new Error("Added line count did not match for hunk at line " + (chunkHeaderIndex + 1));
		}
		if (removeCount !== hunk.oldLines) {
			throw new Error("Removed line count did not match for hunk at line " + (chunkHeaderIndex + 1));
		}
		return hunk;
	}
	while (i$2 < diffstr.length) {
		parseIndex();
	}
	return list;
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/util/distance-iterator.js
function distance_iterator_default(start, minLine, maxLine) {
	let wantForward = true, backwardExhausted = false, forwardExhausted = false, localOffset = 1;
	return function iterator() {
		if (wantForward && !forwardExhausted) {
			if (backwardExhausted) {
				localOffset++;
			} else {
				wantForward = false;
			}
			if (start + localOffset <= maxLine) {
				return start + localOffset;
			}
			forwardExhausted = true;
		}
		if (!backwardExhausted) {
			if (!forwardExhausted) {
				wantForward = true;
			}
			if (minLine <= start - localOffset) {
				return start - localOffset++;
			}
			backwardExhausted = true;
			return iterator();
		}
		return undefined;
	};
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/patch/apply.js
/**
* attempts to apply a unified diff patch.
*
* Hunks are applied first to last.
* `applyPatch` first tries to apply the first hunk at the line number specified in the hunk header, and with all context lines matching exactly.
* If that fails, it tries scanning backwards and forwards, one line at a time, to find a place to apply the hunk where the context lines match exactly.
* If that still fails, and `fuzzFactor` is greater than zero, it increments the maximum number of mismatches (missing, extra, or changed context lines) that there can be between the hunk context and a region where we are trying to apply the patch such that the hunk will still be considered to match.
* Regardless of `fuzzFactor`, lines to be deleted in the hunk *must* be present for a hunk to match, and the context lines *immediately* before and after an insertion must match exactly.
*
* Once a hunk is successfully fitted, the process begins again with the next hunk.
* Regardless of `fuzzFactor`, later hunks must be applied later in the file than earlier hunks.
*
* If a hunk cannot be successfully fitted *anywhere* with fewer than `fuzzFactor` mismatches, `applyPatch` fails and returns `false`.
*
* If a hunk is successfully fitted but not at the line number specified by the hunk header, all subsequent hunks have their target line number adjusted accordingly.
* (e.g. if the first hunk is applied 10 lines below where the hunk header said it should fit, `applyPatch` will *start* looking for somewhere to apply the second hunk 10 lines below where its hunk header says it goes.)
*
* If the patch was applied successfully, returns a string containing the patched text.
* If the patch could not be applied (because some hunks in the patch couldn't be fitted to the text in `source`), `applyPatch` returns false.
*
* @param patch a string diff or the output from the `parsePatch` or `structuredPatch` methods.
*/
function applyPatch(source, patch, options = {}) {
	let patches;
	if (typeof patch === "string") {
		patches = parsePatch(patch);
	} else if (Array.isArray(patch)) {
		patches = patch;
	} else {
		patches = [patch];
	}
	if (patches.length > 1) {
		throw new Error("applyPatch only works with a single input.");
	}
	return applyStructuredPatch(source, patches[0], options);
}
function applyStructuredPatch(source, patch, options = {}) {
	if (options.autoConvertLineEndings || options.autoConvertLineEndings == null) {
		if (hasOnlyWinLineEndings(source) && isUnix(patch)) {
			patch = unixToWin(patch);
		} else if (hasOnlyUnixLineEndings(source) && isWin(patch)) {
			patch = winToUnix(patch);
		}
	}
	const lines = source.split("\n"), hunks = patch.hunks, compareLine = options.compareLine || ((lineNumber, line, operation, patchContent) => line === patchContent), fuzzFactor = options.fuzzFactor || 0;
	let minLine = 0;
	if (fuzzFactor < 0 || !Number.isInteger(fuzzFactor)) {
		throw new Error("fuzzFactor must be a non-negative integer");
	}
	if (!hunks.length) {
		return source;
	}
	let prevLine = "", removeEOFNL = false, addEOFNL = false;
	for (let i$2 = 0; i$2 < hunks[hunks.length - 1].lines.length; i$2++) {
		const line = hunks[hunks.length - 1].lines[i$2];
		if (line[0] == "\\") {
			if (prevLine[0] == "+") {
				removeEOFNL = true;
			} else if (prevLine[0] == "-") {
				addEOFNL = true;
			}
		}
		prevLine = line;
	}
	if (removeEOFNL) {
		if (addEOFNL) {
			if (!fuzzFactor && lines[lines.length - 1] == "") {
				return false;
			}
		} else if (lines[lines.length - 1] == "") {
			lines.pop();
		} else if (!fuzzFactor) {
			return false;
		}
	} else if (addEOFNL) {
		if (lines[lines.length - 1] != "") {
			lines.push("");
		} else if (!fuzzFactor) {
			return false;
		}
	}
	/**
	* Checks if the hunk can be made to fit at the provided location with at most `maxErrors`
	* insertions, substitutions, or deletions, while ensuring also that:
	* - lines deleted in the hunk match exactly, and
	* - wherever an insertion operation or block of insertion operations appears in the hunk, the
	*   immediately preceding and following lines of context match exactly
	*
	* `toPos` should be set such that lines[toPos] is meant to match hunkLines[0].
	*
	* If the hunk can be applied, returns an object with properties `oldLineLastI` and
	* `replacementLines`. Otherwise, returns null.
	*/
	function applyHunk(hunkLines, toPos, maxErrors, hunkLinesI = 0, lastContextLineMatched = true, patchedLines = [], patchedLinesLength = 0) {
		let nConsecutiveOldContextLines = 0;
		let nextContextLineMustMatch = false;
		for (; hunkLinesI < hunkLines.length; hunkLinesI++) {
			const hunkLine = hunkLines[hunkLinesI], operation = hunkLine.length > 0 ? hunkLine[0] : " ", content = hunkLine.length > 0 ? hunkLine.substr(1) : hunkLine;
			if (operation === "-") {
				if (compareLine(toPos + 1, lines[toPos], operation, content)) {
					toPos++;
					nConsecutiveOldContextLines = 0;
				} else {
					if (!maxErrors || lines[toPos] == null) {
						return null;
					}
					patchedLines[patchedLinesLength] = lines[toPos];
					return applyHunk(hunkLines, toPos + 1, maxErrors - 1, hunkLinesI, false, patchedLines, patchedLinesLength + 1);
				}
			}
			if (operation === "+") {
				if (!lastContextLineMatched) {
					return null;
				}
				patchedLines[patchedLinesLength] = content;
				patchedLinesLength++;
				nConsecutiveOldContextLines = 0;
				nextContextLineMustMatch = true;
			}
			if (operation === " ") {
				nConsecutiveOldContextLines++;
				patchedLines[patchedLinesLength] = lines[toPos];
				if (compareLine(toPos + 1, lines[toPos], operation, content)) {
					patchedLinesLength++;
					lastContextLineMatched = true;
					nextContextLineMustMatch = false;
					toPos++;
				} else {
					if (nextContextLineMustMatch || !maxErrors) {
						return null;
					}
					return lines[toPos] && (applyHunk(hunkLines, toPos + 1, maxErrors - 1, hunkLinesI + 1, false, patchedLines, patchedLinesLength + 1) || applyHunk(hunkLines, toPos + 1, maxErrors - 1, hunkLinesI, false, patchedLines, patchedLinesLength + 1)) || applyHunk(hunkLines, toPos, maxErrors - 1, hunkLinesI + 1, false, patchedLines, patchedLinesLength);
				}
			}
		}
		patchedLinesLength -= nConsecutiveOldContextLines;
		toPos -= nConsecutiveOldContextLines;
		patchedLines.length = patchedLinesLength;
		return {
			patchedLines,
			oldLineLastI: toPos - 1
		};
	}
	const resultLines = [];
	let prevHunkOffset = 0;
	for (let i$2 = 0; i$2 < hunks.length; i$2++) {
		const hunk = hunks[i$2];
		let hunkResult;
		const maxLine = lines.length - hunk.oldLines + fuzzFactor;
		let toPos;
		for (let maxErrors = 0; maxErrors <= fuzzFactor; maxErrors++) {
			toPos = hunk.oldStart + prevHunkOffset - 1;
			const iterator = distance_iterator_default(toPos, minLine, maxLine);
			for (; toPos !== undefined; toPos = iterator()) {
				hunkResult = applyHunk(hunk.lines, toPos, maxErrors);
				if (hunkResult) {
					break;
				}
			}
			if (hunkResult) {
				break;
			}
		}
		if (!hunkResult) {
			return false;
		}
		for (let i$3 = minLine; i$3 < toPos; i$3++) {
			resultLines.push(lines[i$3]);
		}
		for (let i$3 = 0; i$3 < hunkResult.patchedLines.length; i$3++) {
			const line = hunkResult.patchedLines[i$3];
			resultLines.push(line);
		}
		minLine = hunkResult.oldLineLastI + 1;
		prevHunkOffset = toPos + 1 - hunk.oldStart;
	}
	for (let i$2 = minLine; i$2 < lines.length; i$2++) {
		resultLines.push(lines[i$2]);
	}
	return resultLines.join("\n");
}
/**
* applies one or more patches.
*
* `patch` may be either an array of structured patch objects, or a string representing a patch in unified diff format (which may patch one or more files).
*
* This method will iterate over the contents of the patch and apply to data provided through callbacks. The general flow for each patch index is:
*
* - `options.loadFile(index, callback)` is called. The caller should then load the contents of the file and then pass that to the `callback(err, data)` callback. Passing an `err` will terminate further patch execution.
* - `options.patched(index, content, callback)` is called once the patch has been applied. `content` will be the return value from `applyPatch`. When it's ready, the caller should call `callback(err)` callback. Passing an `err` will terminate further patch execution.
*
* Once all patches have been applied or an error occurs, the `options.complete(err)` callback is made.
*/
function applyPatches(uniDiff, options) {
	const spDiff = typeof uniDiff === "string" ? parsePatch(uniDiff) : uniDiff;
	let currentIndex = 0;
	function processIndex() {
		const index = spDiff[currentIndex++];
		if (!index) {
			return options.complete();
		}
		options.loadFile(index, function(err, data) {
			if (err) {
				return options.complete(err);
			}
			const updatedContent = applyPatch(data, index, options);
			options.patched(index, updatedContent, function(err$1) {
				if (err$1) {
					return options.complete(err$1);
				}
				processIndex();
			});
		});
	}
	processIndex();
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/patch/reverse.js
function reversePatch(structuredPatch$1) {
	if (Array.isArray(structuredPatch$1)) {
		return structuredPatch$1.map((patch) => reversePatch(patch)).reverse();
	}
	return Object.assign(Object.assign({}, structuredPatch$1), {
		oldFileName: structuredPatch$1.newFileName,
		oldHeader: structuredPatch$1.newHeader,
		newFileName: structuredPatch$1.oldFileName,
		newHeader: structuredPatch$1.oldHeader,
		hunks: structuredPatch$1.hunks.map((hunk) => {
			return {
				oldLines: hunk.newLines,
				oldStart: hunk.newStart,
				newLines: hunk.oldLines,
				newStart: hunk.oldStart,
				lines: hunk.lines.map((l$2) => {
					if (l$2.startsWith("-")) {
						return `+${l$2.slice(1)}`;
					}
					if (l$2.startsWith("+")) {
						return `-${l$2.slice(1)}`;
					}
					return l$2;
				})
			};
		})
	});
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/patch/create.js
const INCLUDE_HEADERS = {
	includeIndex: true,
	includeUnderline: true,
	includeFileHeaders: true
};
const FILE_HEADERS_ONLY = {
	includeIndex: false,
	includeUnderline: false,
	includeFileHeaders: true
};
const OMIT_HEADERS = {
	includeIndex: false,
	includeUnderline: false,
	includeFileHeaders: false
};
function structuredPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, options) {
	let optionsObj;
	if (!options) {
		optionsObj = {};
	} else if (typeof options === "function") {
		optionsObj = { callback: options };
	} else {
		optionsObj = options;
	}
	if (typeof optionsObj.context === "undefined") {
		optionsObj.context = 4;
	}
	const context = optionsObj.context;
	if (optionsObj.newlineIsToken) {
		throw new Error("newlineIsToken may not be used with patch-generation functions, only with diffing functions");
	}
	if (!optionsObj.callback) {
		return diffLinesResultToPatch(diffLines(oldStr, newStr, optionsObj));
	} else {
		const { callback } = optionsObj;
		diffLines(oldStr, newStr, Object.assign(Object.assign({}, optionsObj), { callback: (diff) => {
			const patch = diffLinesResultToPatch(diff);
			callback(patch);
		} }));
	}
	function diffLinesResultToPatch(diff) {
		if (!diff) {
			return;
		}
		diff.push({
			value: "",
			lines: []
		});
		function contextLines(lines) {
			return lines.map(function(entry) {
				return " " + entry;
			});
		}
		const hunks = [];
		let oldRangeStart = 0, newRangeStart = 0, curRange = [], oldLine = 1, newLine = 1;
		for (let i$2 = 0; i$2 < diff.length; i$2++) {
			const current = diff[i$2], lines = current.lines || splitLines(current.value);
			current.lines = lines;
			if (current.added || current.removed) {
				if (!oldRangeStart) {
					const prev = diff[i$2 - 1];
					oldRangeStart = oldLine;
					newRangeStart = newLine;
					if (prev) {
						curRange = context > 0 ? contextLines(prev.lines.slice(-context)) : [];
						oldRangeStart -= curRange.length;
						newRangeStart -= curRange.length;
					}
				}
				for (const line of lines) {
					curRange.push((current.added ? "+" : "-") + line);
				}
				if (current.added) {
					newLine += lines.length;
				} else {
					oldLine += lines.length;
				}
			} else {
				if (oldRangeStart) {
					if (lines.length <= context * 2 && i$2 < diff.length - 2) {
						for (const line of contextLines(lines)) {
							curRange.push(line);
						}
					} else {
						const contextSize = Math.min(lines.length, context);
						for (const line of contextLines(lines.slice(0, contextSize))) {
							curRange.push(line);
						}
						const hunk = {
							oldStart: oldRangeStart,
							oldLines: oldLine - oldRangeStart + contextSize,
							newStart: newRangeStart,
							newLines: newLine - newRangeStart + contextSize,
							lines: curRange
						};
						hunks.push(hunk);
						oldRangeStart = 0;
						newRangeStart = 0;
						curRange = [];
					}
				}
				oldLine += lines.length;
				newLine += lines.length;
			}
		}
		for (const hunk of hunks) {
			for (let i$2 = 0; i$2 < hunk.lines.length; i$2++) {
				if (hunk.lines[i$2].endsWith("\n")) {
					hunk.lines[i$2] = hunk.lines[i$2].slice(0, -1);
				} else {
					hunk.lines.splice(i$2 + 1, 0, "\\ No newline at end of file");
					i$2++;
				}
			}
		}
		return {
			oldFileName,
			newFileName,
			oldHeader,
			newHeader,
			hunks
		};
	}
}
/**
* creates a unified diff patch.
* @param patch either a single structured patch object (as returned by `structuredPatch`) or an array of them (as returned by `parsePatch`)
*/
function formatPatch(patch, headerOptions) {
	if (!headerOptions) {
		headerOptions = INCLUDE_HEADERS;
	}
	if (Array.isArray(patch)) {
		if (patch.length > 1 && !headerOptions.includeFileHeaders) {
			throw new Error("Cannot omit file headers on a multi-file patch. " + "(The result would be unparseable; how would a tool trying to apply " + "the patch know which changes are to which file?)");
		}
		return patch.map((p$1) => formatPatch(p$1, headerOptions)).join("\n");
	}
	const ret = [];
	if (headerOptions.includeIndex && patch.oldFileName == patch.newFileName) {
		ret.push("Index: " + patch.oldFileName);
	}
	if (headerOptions.includeUnderline) {
		ret.push("===================================================================");
	}
	if (headerOptions.includeFileHeaders) {
		ret.push("--- " + patch.oldFileName + (typeof patch.oldHeader === "undefined" ? "" : "	" + patch.oldHeader));
		ret.push("+++ " + patch.newFileName + (typeof patch.newHeader === "undefined" ? "" : "	" + patch.newHeader));
	}
	for (let i$2 = 0; i$2 < patch.hunks.length; i$2++) {
		const hunk = patch.hunks[i$2];
		if (hunk.oldLines === 0) {
			hunk.oldStart -= 1;
		}
		if (hunk.newLines === 0) {
			hunk.newStart -= 1;
		}
		ret.push("@@ -" + hunk.oldStart + "," + hunk.oldLines + " +" + hunk.newStart + "," + hunk.newLines + " @@");
		for (const line of hunk.lines) {
			ret.push(line);
		}
	}
	return ret.join("\n") + "\n";
}
function createTwoFilesPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, options) {
	if (typeof options === "function") {
		options = { callback: options };
	}
	if (!(options === null || options === void 0 ? void 0 : options.callback)) {
		const patchObj = structuredPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, options);
		if (!patchObj) {
			return;
		}
		return formatPatch(patchObj, options === null || options === void 0 ? void 0 : options.headerOptions);
	} else {
		const { callback } = options;
		structuredPatch(oldFileName, newFileName, oldStr, newStr, oldHeader, newHeader, Object.assign(Object.assign({}, options), { callback: (patchObj) => {
			if (!patchObj) {
				callback(undefined);
			} else {
				callback(formatPatch(patchObj, options.headerOptions));
			}
		} }));
	}
}
function createPatch(fileName, oldStr, newStr, oldHeader, newHeader, options) {
	return createTwoFilesPatch(fileName, fileName, oldStr, newStr, oldHeader, newHeader, options);
}
/**
* Split `text` into an array of lines, including the trailing newline character (where present)
*/
function splitLines(text$1) {
	const hasTrailingNl = text$1.endsWith("\n");
	const result = text$1.split("\n").map((line) => line + "\n");
	if (hasTrailingNl) {
		result.pop();
	} else {
		result.push(result.pop().slice(0, -1));
	}
	return result;
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/convert/dmp.js
/**
* converts a list of change objects to the format returned by Google's [diff-match-patch](https://github.com/google/diff-match-patch) library
*/
function convertChangesToDMP(changes) {
	const ret = [];
	let change, operation;
	for (let i$2 = 0; i$2 < changes.length; i$2++) {
		change = changes[i$2];
		if (change.added) {
			operation = 1;
		} else if (change.removed) {
			operation = -1;
		} else {
			operation = 0;
		}
		ret.push([operation, change.value]);
	}
	return ret;
}

//#endregion
//#region ../../node_modules/.bun/diff@8.0.3/node_modules/diff/libesm/convert/xml.js
/**
* converts a list of change objects to a serialized XML format
*/
function convertChangesToXML(changes) {
	const ret = [];
	for (let i$2 = 0; i$2 < changes.length; i$2++) {
		const change = changes[i$2];
		if (change.added) {
			ret.push("<ins>");
		} else if (change.removed) {
			ret.push("<del>");
		}
		ret.push(escapeHTML(change.value));
		if (change.added) {
			ret.push("</ins>");
		} else if (change.removed) {
			ret.push("</del>");
		}
	}
	return ret.join("");
}
function escapeHTML(s$1) {
	let n = s$1;
	n = n.replace(/&/g, "&amp;");
	n = n.replace(/</g, "&lt;");
	n = n.replace(/>/g, "&gt;");
	n = n.replace(/"/g, "&quot;");
	return n;
}

//#endregion
//#region src/utils/cleanLastNewline.ts
function cleanLastNewline(contents) {
	return contents.replace(/\n$|\r\n$/, "");
}

//#endregion
//#region ../../node_modules/.bun/@shikijs+transformers@4.0.2/node_modules/@shikijs/transformers/dist/index.mjs
/**
* some comment formats have to be located at the end of line
* hence we can skip matching them for other tokens
*/
const matchers = [
	[/^(<!--)(.+)(-->)$/, false],
	[/^(\/\*)(.+)(\*\/)$/, false],
	[/^(\/\/|["'#]|;{1,2}|%{1,2}|--)(.*)$/, true],
	[/^(\*)(.+)$/, true]
];
/**
* @param lines line tokens
* @param jsx enable JSX parsing
* @param matchAlgorithm matching algorithm
*/
function parseComments(lines, jsx, matchAlgorithm) {
	const out = [];
	for (const line of lines) {
		if (matchAlgorithm === "v3") {
			const splittedElements = line.children.flatMap((element$1, idx) => {
				if (element$1.type !== "element") return element$1;
				const token$1 = element$1.children[0];
				if (token$1.type !== "text") return element$1;
				const isLast = idx === line.children.length - 1;
				if (!matchToken(token$1.value, isLast)) return element$1;
				const rawSplits = token$1.value.split(/(\s+\/\/)/);
				if (rawSplits.length <= 1) return element$1;
				let splits = [rawSplits[0]];
				for (let i$2 = 1; i$2 < rawSplits.length; i$2 += 2) splits.push(rawSplits[i$2] + (rawSplits[i$2 + 1] || ""));
				splits = splits.filter(Boolean);
				if (splits.length <= 1) return element$1;
				return splits.map((split) => {
					return {
						...element$1,
						children: [{
							type: "text",
							value: split
						}]
					};
				});
			});
			if (splittedElements.length !== line.children.length) line.children = splittedElements;
		}
		const elements = line.children;
		let start = elements.length - 1;
		if (matchAlgorithm === "v1") start = 0;
		else if (jsx) start = elements.length - 2;
		for (let i$2 = Math.max(start, 0); i$2 < elements.length; i$2++) {
			const token$1 = elements[i$2];
			if (token$1.type !== "element") continue;
			const head$1 = token$1.children.at(0);
			if (head$1?.type !== "text") continue;
			const isLast = i$2 === elements.length - 1;
			let match = matchToken(head$1.value, isLast);
			let additionalTokens;
			if (!match && i$2 > 0 && head$1.value.trim().startsWith("[!code")) {
				const prevToken = elements[i$2 - 1];
				if (prevToken?.type === "element") {
					const prevHead = prevToken.children.at(0);
					if (prevHead?.type === "text" && prevHead.value.includes("//")) {
						const combinedMatch = matchToken(prevHead.value + head$1.value, isLast);
						if (combinedMatch) {
							match = combinedMatch;
							out.push({
								info: combinedMatch,
								line,
								token: prevToken,
								isLineCommentOnly: elements.length === 2 && prevToken.children.length === 1 && token$1.children.length === 1,
								isJsxStyle: false,
								additionalTokens: [token$1]
							});
							continue;
						}
					}
				}
			}
			if (!match) continue;
			if (jsx && !isLast && i$2 !== 0) {
				const isJsxStyle = isValue(elements[i$2 - 1], "{") && isValue(elements[i$2 + 1], "}");
				out.push({
					info: match,
					line,
					token: token$1,
					isLineCommentOnly: elements.length === 3 && token$1.children.length === 1,
					isJsxStyle,
					additionalTokens
				});
			} else out.push({
				info: match,
				line,
				token: token$1,
				isLineCommentOnly: elements.length === 1 && token$1.children.length === 1,
				isJsxStyle: false,
				additionalTokens
			});
		}
	}
	return out;
}
function isValue(element$1, value) {
	if (element$1.type !== "element") return false;
	const text$1 = element$1.children[0];
	if (text$1.type !== "text") return false;
	return text$1.value.trim() === value;
}
/**
* @param text text value of comment node
* @param isLast whether the token is located at the end of line
*/
function matchToken(text$1, isLast) {
	let trimmed = text$1.trimStart();
	const spaceFront = text$1.length - trimmed.length;
	trimmed = trimmed.trimEnd();
	const spaceEnd = text$1.length - trimmed.length - spaceFront;
	for (const [matcher, endOfLine] of matchers) {
		if (endOfLine && !isLast) continue;
		const result = matcher.exec(trimmed);
		if (!result) continue;
		return [
			" ".repeat(spaceFront) + result[1],
			result[2],
			result[3] ? result[3] + " ".repeat(spaceEnd) : void 0
		];
	}
}
/**
* Remove empty comment prefixes at line end, e.g. `// `
*
* For matchAlgorithm v1
*/
function v1ClearEndCommentPrefix(text$1) {
	const match = text$1.match(/(?:\/\/|["'#]|;{1,2}|%{1,2}|--)(\s*)$/);
	if (match && match[1].trim().length === 0) return text$1.slice(0, match.index);
	return text$1;
}
function createCommentNotationTransformer(name, regex, onMatch, matchAlgorithm) {
	if (matchAlgorithm == null) matchAlgorithm = "v3";
	return {
		name,
		code(code) {
			const lines = code.children.filter((i$2) => i$2.type === "element");
			const linesToRemove = [];
			code.data ??= {};
			const data = code.data;
			data._shiki_notation ??= parseComments(lines, ["jsx", "tsx"].includes(this.options.lang), matchAlgorithm);
			const parsed = data._shiki_notation;
			for (const comment$1 of parsed) {
				if (comment$1.info[1].length === 0) continue;
				let lineIdx = lines.indexOf(comment$1.line);
				if (comment$1.isLineCommentOnly && matchAlgorithm !== "v1") lineIdx++;
				let replaced = false;
				comment$1.info[1] = comment$1.info[1].replace(regex, (...match) => {
					if (onMatch.call(this, match, comment$1.line, comment$1.token, lines, lineIdx)) {
						replaced = true;
						return "";
					}
					return match[0];
				});
				if (!replaced) continue;
				if (matchAlgorithm === "v1") comment$1.info[1] = v1ClearEndCommentPrefix(comment$1.info[1]);
				const isEmpty = comment$1.info[1].trim().length === 0;
				if (isEmpty) comment$1.info[1] = "";
				if (isEmpty && comment$1.isLineCommentOnly) linesToRemove.push(comment$1.line);
				else if (isEmpty && comment$1.isJsxStyle) comment$1.line.children.splice(comment$1.line.children.indexOf(comment$1.token) - 1, 3);
				else if (isEmpty) {
					if (comment$1.additionalTokens) for (let j$1 = comment$1.additionalTokens.length - 1; j$1 >= 0; j$1--) {
						const additionalToken = comment$1.additionalTokens[j$1];
						const tokenIndex = comment$1.line.children.indexOf(additionalToken);
						if (tokenIndex !== -1) comment$1.line.children.splice(tokenIndex, 1);
					}
					comment$1.line.children.splice(comment$1.line.children.indexOf(comment$1.token), 1);
				} else {
					const head$1 = comment$1.token.children[0];
					if (head$1.type === "text") {
						head$1.value = comment$1.info.join("");
						if (comment$1.additionalTokens) for (const additionalToken of comment$1.additionalTokens) {
							const additionalHead = additionalToken.children[0];
							if (additionalHead?.type === "text") additionalHead.value = "";
						}
					}
				}
			}
			for (const line of linesToRemove) {
				const index = code.children.indexOf(line);
				const nextLine = code.children[index + 1];
				let removeLength = 1;
				if (nextLine?.type === "text" && nextLine?.value === "\n") removeLength = 2;
				code.children.splice(index, removeLength);
			}
		}
	};
}
/**
* Transformer for `shiki`'s legacy `lineOptions`
*/
function transformerCompactLineOptions(lineOptions = []) {
	return {
		name: "@shikijs/transformers:compact-line-options",
		line(node, line) {
			const lineOption = lineOptions.find((o$2) => o$2.line === line);
			if (lineOption?.classes) this.addClassToHast(node, lineOption.classes);
			return node;
		}
	};
}
function parseMetaHighlightString(meta) {
	if (!meta) return null;
	const match = meta.match(/\{([\d,-]+)\}/);
	if (!match) return null;
	return match[1].split(",").flatMap((v$1) => {
		const range$1 = v$1.split("-").map((n) => Number.parseInt(n, 10));
		return range$1.length === 1 ? [range$1[0]] : Array.from({ length: range$1[1] - range$1[0] + 1 }, (_$2, i$2) => range$1[0] + i$2);
	});
}
const symbol = Symbol("highlighted-lines");
/**
* Allow using `{1,3-5}` in the code snippet meta to mark highlighted lines.
*/
function transformerMetaHighlight(options = {}) {
	const { className = "highlighted", zeroIndexed = false } = options;
	return {
		name: "@shikijs/transformers:meta-highlight",
		line(node, lineNumber) {
			if (!this.options.meta?.__raw) return;
			const meta = this.meta;
			meta[symbol] ??= parseMetaHighlightString(this.options.meta.__raw);
			const highlightedLines = meta[symbol] ?? [];
			const effectiveLine = zeroIndexed ? lineNumber - 1 : lineNumber;
			if (highlightedLines.includes(effectiveLine)) this.addClassToHast(node, className);
			return node;
		}
	};
}
function parseMetaHighlightWords(meta) {
	if (!meta) return [];
	return Array.from(meta.matchAll(/\/((?:\\.|[^/])+)\//g)).map((v$1) => v$1[1].replace(/\\(.)/g, "$1"));
}
/**
* Allow using `/word/` in the code snippet meta to mark highlighted words.
*/
function transformerMetaWordHighlight(options = {}) {
	const { className = "highlighted-word" } = options;
	return {
		name: "@shikijs/transformers:meta-word-highlight",
		preprocess(code, options$1) {
			if (!this.options.meta?.__raw) return;
			const words = parseMetaHighlightWords(this.options.meta.__raw);
			options$1.decorations ||= [];
			for (const word of words) {
				const indexes = findAllSubstringIndexes(code, word);
				for (const index of indexes) options$1.decorations.push({
					start: index,
					end: index + word.length,
					properties: { class: className }
				});
			}
		}
	};
}
function findAllSubstringIndexes(str, substr) {
	const indexes = [];
	let cursor = 0;
	while (true) {
		const index = str.indexOf(substr, cursor);
		if (index === -1 || index >= str.length) break;
		if (index < cursor) break;
		indexes.push(index);
		cursor = index + substr.length;
	}
	return indexes;
}
function escapeRegExp(str) {
	return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function transformerNotationMap(options = {}, name = "@shikijs/transformers:notation-map") {
	const { classMap = {}, classActivePre = void 0, classActiveCode = void 0 } = options;
	return createCommentNotationTransformer(name, new RegExp(`#?\\s*\\[!code (${Object.keys(classMap).map(escapeRegExp).join("|")})(:\\d+)?\\]`, "gi"), function([_$2, match, range$1 = ":1"], _line, _comment, lines, index) {
		const lineNum = Number.parseInt(range$1.slice(1), 10);
		for (let i$2 = index; i$2 < Math.min(index + lineNum, lines.length); i$2++) this.addClassToHast(lines[i$2], classMap[match]);
		if (classActivePre) this.addClassToHast(this.pre, classActivePre);
		if (classActiveCode) this.addClassToHast(this.code, classActiveCode);
		return true;
	}, options.matchAlgorithm);
}
/**
* Use `[!code ++]` and `[!code --]` to mark added and removed lines.
*/
function transformerNotationDiff(options = {}) {
	const { classLineAdd = "diff add", classLineRemove = "diff remove", classActivePre = "has-diff", classActiveCode } = options;
	return transformerNotationMap({
		classMap: {
			"++": classLineAdd,
			"--": classLineRemove
		},
		classActivePre,
		classActiveCode,
		matchAlgorithm: options.matchAlgorithm
	}, "@shikijs/transformers:notation-diff");
}
/**
* Allow using `[!code error]` `[!code warning]` notation in code to mark highlighted lines.
*/
function transformerNotationErrorLevel(options = {}) {
	const { classMap = {
		error: ["highlighted", "error"],
		warning: ["highlighted", "warning"],
		info: ["highlighted", "info"]
	}, classActivePre = "has-highlighted", classActiveCode } = options;
	return transformerNotationMap({
		classMap,
		classActivePre,
		classActiveCode,
		matchAlgorithm: options.matchAlgorithm
	}, "@shikijs/transformers:notation-error-level");
}
/**
* Allow using `[!code focus]` notation in code to mark focused lines.
*/
function transformerNotationFocus(options = {}) {
	const { classActiveLine = "focused", classActivePre = "has-focused", classActiveCode } = options;
	return transformerNotationMap({
		classMap: { focus: classActiveLine },
		classActivePre,
		classActiveCode,
		matchAlgorithm: options.matchAlgorithm
	}, "@shikijs/transformers:notation-focus");
}
/**
* Allow using `[!code highlight]` notation in code to mark highlighted lines.
*/
function transformerNotationHighlight(options = {}) {
	const { classActiveLine = "highlighted", classActivePre = "has-highlighted", classActiveCode } = options;
	return transformerNotationMap({
		classMap: {
			highlight: classActiveLine,
			hl: classActiveLine
		},
		classActivePre,
		classActiveCode,
		matchAlgorithm: options.matchAlgorithm
	}, "@shikijs/transformers:notation-highlight");
}
function highlightWordInLine(line, ignoredElement, word, className) {
	const content = getTextContent(line);
	let index = content.indexOf(word);
	while (index !== -1) {
		highlightRange.call(this, line.children, ignoredElement, index, word.length, className);
		index = content.indexOf(word, index + 1);
	}
}
function getTextContent(element$1) {
	if (element$1.type === "text") return element$1.value;
	if (element$1.type === "element" && element$1.tagName === "span") return element$1.children.map(getTextContent).join("");
	return "";
}
/**
* @param elements
* @param ignoredElement
* @param index highlight beginning index
* @param len highlight length
* @param className class name to add to highlighted nodes
*/
function highlightRange(elements, ignoredElement, index, len, className) {
	let currentIdx = 0;
	for (let i$2 = 0; i$2 < elements.length; i$2++) {
		const element$1 = elements[i$2];
		if (element$1.type !== "element" || element$1.tagName !== "span" || element$1 === ignoredElement) continue;
		const textNode = element$1.children[0];
		if (textNode.type !== "text") continue;
		if (hasOverlap([currentIdx, currentIdx + textNode.value.length - 1], [index, index + len])) {
			const start = Math.max(0, index - currentIdx);
			const length = len - Math.max(0, currentIdx - index);
			if (length === 0) continue;
			const separated = separateToken(element$1, textNode, start, length);
			this.addClassToHast(separated[1], className);
			const output = separated.filter(Boolean);
			elements.splice(i$2, 1, ...output);
			i$2 += output.length - 1;
		}
		currentIdx += textNode.value.length;
	}
}
function hasOverlap(range1, range2) {
	return range1[0] <= range2[1] && range1[1] >= range2[0];
}
function separateToken(span, textNode, index, len) {
	const text$1 = textNode.value;
	const createNode = (value) => inheritElement(span, { children: [{
		type: "text",
		value
	}] });
	return [
		index > 0 ? createNode(text$1.slice(0, index)) : void 0,
		createNode(text$1.slice(index, index + len)),
		index + len < text$1.length ? createNode(text$1.slice(index + len)) : void 0
	];
}
function inheritElement(original, overrides) {
	return {
		...original,
		properties: { ...original.properties },
		...overrides
	};
}
function transformerNotationWordHighlight(options = {}) {
	const { classActiveWord = "highlighted-word", classActivePre = void 0 } = options;
	return createCommentNotationTransformer("@shikijs/transformers:notation-highlight-word", /\s*\[!code word:((?:\\.|[^:\]])+)(:\d+)?\]/, function([_$2, word, range$1], _line, comment$1, lines, index) {
		const lineNum = range$1 ? Number.parseInt(range$1.slice(1), 10) : lines.length;
		word = word.replace(/\\(.)/g, "$1");
		for (let i$2 = index; i$2 < Math.min(index + lineNum, lines.length); i$2++) highlightWordInLine.call(this, lines[i$2], comment$1, word, classActiveWord);
		if (classActivePre) this.addClassToHast(this.pre, classActivePre);
		return true;
	}, options.matchAlgorithm);
}
/**
* Remove comments from the code.
*/
function transformerRemoveComments(options = {}) {
	const { removeEmptyLines = true } = options;
	return {
		name: "@shikijs/transformers:remove-comments",
		preprocess(_code, options$1) {
			if (options$1.includeExplanation !== true && options$1.includeExplanation !== "scopeName") throw new Error("`transformerRemoveComments` requires `includeExplanation` to be set to `true` or `'scopeName'`");
		},
		tokens(tokens) {
			const result = [];
			for (const line of tokens) {
				const filteredLine = [];
				let hasComment = false;
				for (const token$1 of line) if (token$1.explanation?.some((exp) => exp.scopes.some((s$1) => s$1.scopeName.startsWith("comment")))) hasComment = true;
				else filteredLine.push(token$1);
				if (removeEmptyLines && hasComment) {
					if (filteredLine.every((token$1) => !token$1.content.trim())) continue;
				}
				result.push(filteredLine);
			}
			return result;
		}
	};
}
/**
* Remove line breaks between lines.
* Useful when you override `display: block` to `.line` in CSS.
*/
function transformerRemoveLineBreak() {
	return {
		name: "@shikijs/transformers:remove-line-break",
		code(code) {
			code.children = code.children.filter((line) => !(line.type === "text" && line.value === "\n"));
		}
	};
}
/**
* Remove notation escapes.
* Useful when you want to write `// [!code` in markdown.
* If you process `// [\!code ...]` expression, you can get `// [!code ...]` in the output.
*/
function transformerRemoveNotationEscape() {
	return {
		name: "@shikijs/transformers:remove-notation-escape",
		code(hast) {
			function replace(node) {
				if (node.type === "text") node.value = node.value.replace("[\\!code", "[!code");
				else if ("children" in node) for (const child of node.children) replace(child);
			}
			replace(hast);
			return hast;
		}
	};
}
/**
* Render indentations as separate tokens.
* Apply with CSS, it can be used to render indent guides visually.
*/
function transformerRenderIndentGuides(options = {}) {
	return {
		name: "@shikijs/transformers:render-indent-guides",
		code(hast) {
			const indent = Number(this.options.meta?.indent ?? this.options.meta?.__raw?.match(/\{indent:(\d+|false)\}/)?.[1] ?? options.indent ?? 2);
			if (Number.isNaN(indent) || indent <= 0) return hast;
			const indentRegex = new RegExp(` {${indent}}| {0,${indent - 1}}\t| {1,}$`, "g");
			const emptyLines = [];
			let level = 0;
			for (const line of hast.children) {
				if (line.type !== "element") continue;
				const first = line.children[0];
				if (first?.type !== "element" || first?.children[0]?.type !== "text") {
					emptyLines.push([line, level]);
					continue;
				}
				const text$1 = first.children[0];
				const blanks = text$1.value.split(/[^ \t]/, 1)[0];
				const ranges = [];
				for (const match of blanks.matchAll(indentRegex)) {
					const start = match.index;
					const end = start + match[0].length;
					ranges.push([start, end]);
				}
				for (const [line$1, level$1] of emptyLines) line$1.children.unshift(...Array.from({ length: Math.min(ranges.length, level$1 + 1) }, (_$2, i$2) => ({
					type: "element",
					tagName: "span",
					properties: {
						class: "indent",
						style: `--indent-offset: ${i$2 * indent}ch;`
					},
					children: []
				})));
				emptyLines.length = 0;
				level = ranges.length;
				if (ranges.length) {
					line.children.unshift(...ranges.map(([start, end]) => ({
						type: "element",
						tagName: "span",
						properties: { class: "indent" },
						children: [{
							type: "text",
							value: text$1.value.slice(start, end)
						}]
					})));
					text$1.value = text$1.value.slice(ranges.at(-1)[1]);
				}
			}
			return hast;
		}
	};
}
function isTab(part) {
	return part === "	";
}
function isSpace(part) {
	return part === " " || part === "	";
}
function separateContinuousSpaces(inputs) {
	const result = [];
	let current = "";
	function bump() {
		if (current.length) result.push(current);
		current = "";
	}
	inputs.forEach((part, idx) => {
		if (isTab(part)) {
			bump();
			result.push(part);
		} else if (isSpace(part) && (isSpace(inputs[idx - 1]) || isSpace(inputs[idx + 1]))) {
			bump();
			result.push(part);
		} else current += part;
	});
	bump();
	return result;
}
function splitSpaces(parts, type, renderContinuousSpaces = true) {
	if (type === "all") return parts;
	let leftCount = 0;
	let rightCount = 0;
	if (type === "boundary" || type === "leading") for (let i$2 = 0; i$2 < parts.length; i$2++) if (isSpace(parts[i$2])) leftCount++;
	else break;
	if (type === "boundary" || type === "trailing") for (let i$2 = parts.length - 1; i$2 >= 0; i$2--) if (isSpace(parts[i$2])) rightCount++;
	else break;
	const middle = parts.slice(leftCount, parts.length - rightCount);
	return [
		...parts.slice(0, leftCount),
		...renderContinuousSpaces ? separateContinuousSpaces(middle) : [middle.join("")],
		...parts.slice(parts.length - rightCount)
	];
}
/**
* Render whitespaces as separate tokens.
* Apply with CSS, it can be used to render tabs and spaces visually.
*/
function transformerRenderWhitespace(options = {}) {
	const classMap = {
		" ": options.classSpace ?? "space",
		"	": options.classTab ?? "tab"
	};
	const position = options.position ?? "all";
	const keys = Object.keys(classMap);
	return {
		name: "@shikijs/transformers:render-whitespace",
		root(root$1) {
			const pre = root$1.children[0];
			(pre.tagName === "pre" ? pre.children[0] : { children: [root$1] }).children.forEach((line) => {
				if (line.type !== "element" && line.type !== "root") return;
				const elements = line.children.filter((token$1) => token$1.type === "element");
				const last = elements.length - 1;
				line.children = line.children.flatMap((token$1) => {
					if (token$1.type !== "element") return token$1;
					const index = elements.indexOf(token$1);
					if (position === "boundary" && index !== 0 && index !== last) return token$1;
					if (position === "trailing" && index !== last) return token$1;
					if (position === "leading" && index !== 0) return token$1;
					const node = token$1.children[0];
					if (node.type !== "text" || !node.value) return token$1;
					const parts = splitSpaces(node.value.split(/([ \t])/).filter((i$2) => i$2.length), position === "boundary" && index === last && last !== 0 ? "trailing" : position, position !== "trailing" && position !== "leading");
					if (parts.length <= 1) return token$1;
					return parts.map((part) => {
						const clone$1 = {
							...token$1,
							properties: { ...token$1.properties }
						};
						clone$1.children = [{
							type: "text",
							value: part
						}];
						if (keys.includes(part)) {
							this.addClassToHast(clone$1, classMap[part]);
							delete clone$1.properties.style;
						}
						return clone$1;
					});
				});
			});
		}
	};
}
/**
* Remove line breaks between lines.
* Useful when you override `display: block` to `.line` in CSS.
*/
function transformerStyleToClass(options = {}) {
	const { classPrefix = "__shiki_", classSuffix = "", classReplacer = (className) => className } = options;
	const classToStyle = /* @__PURE__ */ new Map();
	function stringifyStyle(style) {
		return Object.entries(style).map(([key$1, value]) => `${key$1}:${value}`).join(";");
	}
	function registerStyle(style) {
		let className = classPrefix + cyrb53(typeof style === "string" ? style : stringifyStyle(style)) + classSuffix;
		className = classReplacer(className);
		if (!classToStyle.has(className)) classToStyle.set(className, typeof style === "string" ? style : { ...style });
		return className;
	}
	return {
		name: "@shikijs/transformers:style-to-class",
		pre(t) {
			if (!t.properties.style) return;
			const className = registerStyle(t.properties.style);
			delete t.properties.style;
			this.addClassToHast(t, className);
		},
		tokens(lines) {
			for (const line of lines) for (const token$1 of line) {
				if (!token$1.htmlStyle) continue;
				const className = registerStyle(token$1.htmlStyle);
				token$1.htmlStyle = {};
				token$1.htmlAttrs ||= {};
				if (!token$1.htmlAttrs.class) token$1.htmlAttrs.class = className;
				else token$1.htmlAttrs.class += ` ${className}`;
			}
		},
		getClassRegistry() {
			return classToStyle;
		},
		getCSS() {
			let css = "";
			for (const [className, style] of classToStyle.entries()) css += `.${className}{${typeof style === "string" ? style : stringifyStyle(style)}}`;
			return css;
		},
		clearRegistry() {
			classToStyle.clear();
		}
	};
}
/**
* A simple hash function.
*
* @see https://stackoverflow.com/a/52171480
*/
function cyrb53(str, seed = 0) {
	let h1 = 3735928559 ^ seed;
	let h2 = 1103547991 ^ seed;
	for (let i$2 = 0, ch; i$2 < str.length; i$2++) {
		ch = str.charCodeAt(i$2);
		h1 = Math.imul(h1 ^ ch, 2654435761);
		h2 = Math.imul(h2 ^ ch, 1597334677);
	}
	h1 = Math.imul(h1 ^ h1 >>> 16, 2246822507);
	h1 ^= Math.imul(h2 ^ h2 >>> 13, 3266489909);
	h2 = Math.imul(h2 ^ h2 >>> 16, 2246822507);
	h2 ^= Math.imul(h1 ^ h1 >>> 13, 3266489909);
	return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(36).slice(0, 6);
}

//#endregion
//#region src/utils/hast_utils.ts
function createTextNodeElement(value) {
	return {
		type: "text",
		value
	};
}
function createHastElement({ tagName, children = [], properties = {} }) {
	return {
		type: "element",
		tagName,
		properties,
		children
	};
}
function createIconElement({ name, width = 16, height = 16, properties }) {
	return createHastElement({
		tagName: "svg",
		properties: {
			width,
			height,
			viewBox: "0 0 16 16",
			...properties
		},
		children: [createHastElement({
			tagName: "use",
			properties: { href: `#${name.replace(/^#/, "")}` }
		})]
	});
}
function findCodeElement(nodes) {
	let firstChild = nodes.children[0];
	while (firstChild != null) {
		if (firstChild.type === "element" && firstChild.tagName === "code") {
			return firstChild;
		}
		if ("children" in firstChild) {
			firstChild = firstChild.children[0];
		} else {
			firstChild = null;
		}
	}
	return undefined;
}
function createGutterWrapper(children) {
	return createHastElement({
		tagName: "div",
		properties: { "data-gutter": "" },
		children
	});
}
function createGutterItem(lineType, lineNumber, lineIndex, properties = {}) {
	return createHastElement({
		tagName: "div",
		properties: {
			"data-line-type": lineType,
			"data-column-number": lineNumber,
			"data-line-index": lineIndex,
			...properties
		},
		children: lineNumber != null ? [createHastElement({
			tagName: "span",
			properties: { "data-line-number-content": "" },
			children: [createTextNodeElement(`${lineNumber}`)]
		})] : undefined
	});
}
function createGutterGap(type, bufferType, size) {
	return createHastElement({
		tagName: "div",
		properties: {
			"data-gutter-buffer": bufferType,
			"data-buffer-size": size,
			"data-line-type": bufferType === "annotation" ? undefined : type,
			style: bufferType === "annotation" ? `grid-row: span ${size};` : `grid-row: span ${size};min-height:calc(${size} * 1lh);`
		}
	});
}

//#endregion
//#region src/utils/processLine.ts
function processLine(node, line, state) {
	const lineInfo = typeof state.lineInfo === "function" ? state.lineInfo(line) : state.lineInfo[line - 1];
	if (lineInfo == null) {
		const errorMessage = `processLine: line ${line}, contains no state.lineInfo`;
		console.error(errorMessage, {
			node,
			line,
			state
		});
		throw new Error(errorMessage);
	}
	node.tagName = "div";
	node.properties["data-line"] = lineInfo.lineNumber;
	node.properties["data-alt-line"] = lineInfo.altLineNumber;
	node.properties["data-line-type"] = lineInfo.type;
	node.properties["data-line-index"] = lineInfo.lineIndex;
	if (node.children.length === 0) {
		node.children.push(createTextNodeElement("\n"));
	}
	return node;
}

//#endregion
//#region src/utils/wrapTokenFragments.ts
const NO_TOKEN = Symbol("no-token");
const MULTIPLE_TOKENS = Symbol("multiple-tokens");
function wrapTokenFragments(container) {
	const ownTokenChar = getTokenChar(container);
	if (ownTokenChar != null) {
		return ownTokenChar;
	}
	let containerTokenState = NO_TOKEN;
	const wrappedChildren = [];
	let currentTokenChildren = [];
	let currentTokenChar;
	const flushTokenChildren = () => {
		if (currentTokenChildren.length === 0 || currentTokenChar == null) {
			currentTokenChildren = [];
			currentTokenChar = undefined;
			return;
		}
		if (currentTokenChildren.length === 1) {
			const child = currentTokenChildren[0];
			if (child?.type === "element") {
				setTokenChar(child, currentTokenChar);
				for (const grandChild of child.children) {
					stripTokenChar(grandChild);
				}
			} else {
				stripTokenChar(child);
			}
			wrappedChildren.push(child);
			currentTokenChildren = [];
			currentTokenChar = undefined;
			return;
		}
		for (const child of currentTokenChildren) {
			stripTokenChar(child);
		}
		wrappedChildren.push(createHastElement({
			tagName: "span",
			properties: { "data-char": currentTokenChar },
			children: currentTokenChildren
		}));
		currentTokenChildren = [];
		currentTokenChar = undefined;
	};
	const mergeContainerTokenState = (childTokenState) => {
		if (childTokenState === NO_TOKEN) {
			return;
		}
		if (childTokenState === MULTIPLE_TOKENS) {
			containerTokenState = MULTIPLE_TOKENS;
			return;
		}
		if (containerTokenState === NO_TOKEN) {
			containerTokenState = childTokenState;
			return;
		}
		if (containerTokenState !== childTokenState) {
			containerTokenState = MULTIPLE_TOKENS;
		}
	};
	for (const child of container.children) {
		const childTokenState = child.type === "element" ? wrapTokenFragments(child) : NO_TOKEN;
		mergeContainerTokenState(childTokenState);
		if (typeof childTokenState !== "number") {
			flushTokenChildren();
			wrappedChildren.push(child);
			continue;
		}
		if (currentTokenChar != null && currentTokenChar !== childTokenState) {
			flushTokenChildren();
		}
		currentTokenChar ??= childTokenState;
		currentTokenChildren.push(child);
	}
	flushTokenChildren();
	container.children = wrappedChildren;
	return containerTokenState;
}
function getTokenChar(node) {
	const value = node.properties["data-char"];
	if (typeof value === "number") {
		return value;
	}
	return undefined;
}
function stripTokenChar(node) {
	if (node.type !== "element") return;
	node.properties["data-char"] = undefined;
	for (const child of node.children) {
		stripTokenChar(child);
	}
}
function setTokenChar(node, char) {
	node.properties["data-char"] = char;
}

//#endregion
//#region src/utils/createTransformerWithState.ts
function createTransformerWithState(useTokenTransformer = false, useCSSClasses = false) {
	const state = { lineInfo: [] };
	const transformers = [{
		line(node) {
			delete node.properties.class;
			return node;
		},
		pre(pre) {
			const code = findCodeElement(pre);
			const children = [];
			if (code != null) {
				let index = 1;
				for (const node of code.children) {
					if (node.type !== "element") continue;
					if (useTokenTransformer) {
						wrapTokenFragments(node);
					}
					children.push(processLine(node, index, state));
					index++;
				}
				code.children = children;
			}
			return pre;
		},
		...useTokenTransformer ? {
			tokens(lines) {
				for (const line of lines) {
					let col = 0;
					for (const token$1 of line) {
						const tokenWithOriginalRange = token$1;
						tokenWithOriginalRange.__lineChar ??= col;
						col += token$1.content.length;
					}
				}
			},
			preprocess(_code, options) {
				options.mergeWhitespaces = "never";
			},
			span(hast, _line, _char, _lineElement, token$1) {
				if (token$1?.offset != null && token$1.content != null) {
					const tokenWithOriginalRange = token$1;
					const tokenChar = tokenWithOriginalRange.__lineChar;
					if (tokenChar != null) {
						hast.properties["data-char"] = tokenChar;
					}
					return hast;
				}
				return hast;
			}
		} : null
	}];
	if (useCSSClasses) {
		transformers.push(tokenStyleNormalizer, toClass);
	}
	return {
		state,
		transformers,
		toClass
	};
}
const toClass = transformerStyleToClass({ classPrefix: "hl-" });
const tokenStyleNormalizer = {
	name: "token-style-normalizer",
	tokens(lines) {
		for (const line of lines) {
			for (const token$1 of line) {
				if (token$1.htmlStyle != null) continue;
				const style = {};
				if (token$1.color != null) {
					style.color = token$1.color;
				}
				if (token$1.bgColor != null) {
					style["background-color"] = token$1.bgColor;
				}
				if (token$1.fontStyle != null && token$1.fontStyle !== 0) {
					if ((token$1.fontStyle & 1) !== 0) {
						style["font-style"] = "italic";
					}
					if ((token$1.fontStyle & 2) !== 0) {
						style["font-weight"] = "bold";
					}
					if ((token$1.fontStyle & 4) !== 0) {
						style["text-decoration"] = "underline";
					}
				}
				if (Object.keys(style).length > 0) {
					token$1.htmlStyle = style;
				}
			}
		}
	}
};

//#endregion
//#region src/utils/formatCSSVariablePrefix.ts
function formatCSSVariablePrefix(type) {
	return `--${type === "token" ? "diffs-token" : "diffs"}-`;
}

//#endregion
//#region src/utils/getHighlighterThemeStyles.ts
function getHighlighterThemeStyles({ theme = DEFAULT_THEMES, highlighter: highlighter$1, prefix }) {
	let styles = "";
	if (typeof theme === "string") {
		const themeData = highlighter$1.getTheme(theme);
		styles += `color:${themeData.fg};`;
		styles += `background-color:${themeData.bg};`;
		styles += `${formatCSSVariablePrefix("global")}fg:${themeData.fg};`;
		styles += `${formatCSSVariablePrefix("global")}bg:${themeData.bg};`;
		styles += getThemeVariables(themeData, prefix);
	} else {
		let themeData = highlighter$1.getTheme(theme.dark);
		styles += `${formatCSSVariablePrefix("global")}dark:${themeData.fg};`;
		styles += `${formatCSSVariablePrefix("global")}dark-bg:${themeData.bg};`;
		styles += getThemeVariables(themeData, "dark");
		themeData = highlighter$1.getTheme(theme.light);
		styles += `${formatCSSVariablePrefix("global")}light:${themeData.fg};`;
		styles += `${formatCSSVariablePrefix("global")}light-bg:${themeData.bg};`;
		styles += getThemeVariables(themeData, "light");
	}
	return styles;
}
function getThemeVariables(themeData, modePrefix) {
	modePrefix = modePrefix != null ? `${modePrefix}-` : "";
	let styles = "";
	const additionGreen = themeData.colors?.["gitDecoration.addedResourceForeground"] ?? themeData.colors?.["terminal.ansiGreen"];
	if (additionGreen != null) {
		styles += `${formatCSSVariablePrefix("global")}${modePrefix}addition-color:${additionGreen};`;
	}
	const deletionRed = themeData.colors?.["gitDecoration.deletedResourceForeground"] ?? themeData.colors?.["terminal.ansiRed"];
	if (deletionRed != null) {
		styles += `${formatCSSVariablePrefix("global")}${modePrefix}deletion-color:${deletionRed};`;
	}
	const modifiedBlue = themeData.colors?.["gitDecoration.modifiedResourceForeground"] ?? themeData.colors?.["terminal.ansiBlue"];
	if (modifiedBlue != null) {
		styles += `${formatCSSVariablePrefix("global")}${modePrefix}modified-color:${modifiedBlue};`;
	}
	return styles;
}

//#endregion
//#region src/utils/getLineNodes.ts
function getLineNodes(nodes) {
	let firstChild = nodes.children[0];
	while (firstChild != null) {
		if (firstChild.type === "element" && firstChild.tagName === "code") {
			return firstChild.children;
		}
		if ("children" in firstChild) {
			firstChild = firstChild.children[0];
		} else {
			firstChild = null;
		}
	}
	console.error(nodes);
	throw new Error("getLineNodes: Unable to find children");
}

//#endregion
//#region src/utils/computeVirtualFileMetrics.ts
function computeVirtualFileMetrics(metrics) {
	return {
		...DEFAULT_VIRTUAL_FILE_METRICS,
		...metrics
	};
}
function getVirtualFileHeaderRegion(metrics, disableFileHeader) {
	const paddingTop = getVirtualFilePaddingTop(metrics, disableFileHeader);
	return disableFileHeader ? paddingTop : metrics.diffHeaderHeight + paddingTop;
}
function getVirtualFilePaddingTop(metrics, disableFileHeader) {
	return metrics.paddingTop ?? (disableFileHeader ? metrics.spacing : 0);
}
function getVirtualFilePaddingBottom(metrics) {
	return metrics.paddingBottom ?? metrics.spacing;
}
function getDefaultHunkSeparatorHeight(type) {
	switch (type) {
		case "simple": return 4;
		case "metadata":
		case "line-info":
		case "line-info-basic":
		case "custom": return 32;
	}
}

//#endregion
//#region src/utils/virtualDiffLayout.ts
function getExpandedRegion({ isPartial, rangeSize, expandedHunks, hunkIndex, collapsedContextThreshold }) {
	const normalizedRangeSize = Math.max(rangeSize, 0);
	if (normalizedRangeSize === 0 || isPartial) {
		return {
			fromStart: 0,
			fromEnd: 0,
			rangeSize: normalizedRangeSize,
			collapsedLines: normalizedRangeSize,
			renderAll: false
		};
	}
	if (expandedHunks === true || normalizedRangeSize <= collapsedContextThreshold) {
		return {
			fromStart: normalizedRangeSize,
			fromEnd: 0,
			rangeSize: normalizedRangeSize,
			collapsedLines: 0,
			renderAll: true
		};
	}
	const region = expandedHunks?.get(hunkIndex);
	const fromStart = Math.min(Math.max(region?.fromStart ?? 0, 0), normalizedRangeSize);
	const fromEnd = Math.min(Math.max(region?.fromEnd ?? 0, 0), normalizedRangeSize);
	const expandedCount = fromStart + fromEnd;
	const renderAll = expandedCount >= normalizedRangeSize;
	return {
		fromStart: renderAll ? normalizedRangeSize : fromStart,
		fromEnd: renderAll ? 0 : fromEnd,
		rangeSize: normalizedRangeSize,
		collapsedLines: Math.max(normalizedRangeSize - expandedCount, 0),
		renderAll
	};
}
function hasTrailingContext(fileDiff) {
	const lastHunk = fileDiff.hunks[fileDiff.hunks.length - 1];
	if (lastHunk == null || fileDiff.isPartial || fileDiff.additionLines.length === 0 || fileDiff.deletionLines.length === 0) {
		return false;
	}
	const additionRemaining = fileDiff.additionLines.length - (lastHunk.additionLineIndex + lastHunk.additionCount);
	const deletionRemaining = fileDiff.deletionLines.length - (lastHunk.deletionLineIndex + lastHunk.deletionCount);
	return additionRemaining > 0 || deletionRemaining > 0;
}
function getTrailingContextRangeSize({ fileDiff, errorPrefix }) {
	const lastHunk = fileDiff.hunks[fileDiff.hunks.length - 1];
	if (lastHunk == null || fileDiff.isPartial || fileDiff.additionLines.length === 0 || fileDiff.deletionLines.length === 0) {
		return 0;
	}
	const additionRemaining = fileDiff.additionLines.length - (lastHunk.additionLineIndex + lastHunk.additionCount);
	const deletionRemaining = fileDiff.deletionLines.length - (lastHunk.deletionLineIndex + lastHunk.deletionCount);
	if (additionRemaining <= 0 && deletionRemaining <= 0) {
		return 0;
	}
	if (additionRemaining !== deletionRemaining) {
		throw new Error(`${errorPrefix}: trailing context mismatch (additions=${additionRemaining}, deletions=${deletionRemaining}) for ${fileDiff.name}`);
	}
	return Math.min(additionRemaining, deletionRemaining);
}
function getTrailingExpandedRegion({ fileDiff, hunkIndex, expandedHunks, collapsedContextThreshold, errorPrefix }) {
	if (hunkIndex !== fileDiff.hunks.length - 1) {
		return undefined;
	}
	const trailingRangeSize = getTrailingContextRangeSize({
		fileDiff,
		errorPrefix
	});
	if (trailingRangeSize <= 0) {
		return undefined;
	}
	if (expandedHunks === true || trailingRangeSize <= collapsedContextThreshold) {
		return {
			fromStart: trailingRangeSize,
			fromEnd: 0,
			rangeSize: trailingRangeSize,
			collapsedLines: 0,
			renderAll: true
		};
	}
	const region = expandedHunks?.get(fileDiff.hunks.length);
	const fromStart = Math.min(Math.max(region?.fromStart ?? 0, 0), trailingRangeSize);
	return {
		fromStart,
		fromEnd: 0,
		rangeSize: trailingRangeSize,
		collapsedLines: trailingRangeSize - fromStart,
		renderAll: fromStart >= trailingRangeSize
	};
}
function getHunkSeparatorHeight({ type, metrics }) {
	return metrics.hunkSeparatorHeight ?? getDefaultHunkSeparatorHeight(type);
}
function getHunkSeparatorGap({ type, metrics }) {
	return type === "simple" || type === "metadata" || type === "line-info-basic" ? 0 : metrics.spacing;
}
function hasLeadingHunkSeparator({ type, hunkIndex, hunkSpecs }) {
	switch (type) {
		case "simple": return hunkIndex > 0;
		case "metadata": return hunkSpecs != null;
		case "line-info":
		case "line-info-basic":
		case "custom": return true;
	}
}
function hasTrailingHunkSeparator(type) {
	return type !== "simple" && type !== "metadata";
}
function getLeadingHunkSeparatorLayout({ type, metrics, hunkIndex, hunkSpecs }) {
	if (!hasLeadingHunkSeparator({
		type,
		hunkIndex,
		hunkSpecs
	})) {
		return undefined;
	}
	const height = getHunkSeparatorHeight({
		type,
		metrics
	});
	const gap = getHunkSeparatorGap({
		type,
		metrics
	});
	const gapBefore = hunkIndex > 0 ? gap : 0;
	const gapAfter = gap;
	return {
		height,
		gapBefore,
		gapAfter,
		totalHeight: gapBefore + height + gapAfter
	};
}
function getTrailingHunkSeparatorLayout({ type, metrics }) {
	if (!hasTrailingHunkSeparator(type)) {
		return undefined;
	}
	const height = getHunkSeparatorHeight({
		type,
		metrics
	});
	const gapBefore = getHunkSeparatorGap({
		type,
		metrics
	});
	return {
		height,
		gapBefore,
		gapAfter: 0,
		totalHeight: gapBefore + height
	};
}

//#endregion
//#region src/utils/iterateOverDiff.ts
function iterateOverDiff({ diff, diffStyle, startingLine = 0, totalLines = Infinity, expandedHunks, collapsedContextThreshold = DEFAULT_COLLAPSED_CONTEXT_THRESHOLD, callback }) {
	const iterationStart = getIterationStartState({
		diff,
		diffStyle,
		startingLine,
		expandedHunks,
		collapsedContextThreshold
	});
	const state = {
		viewportStart: startingLine,
		viewportEnd: startingLine + totalLines,
		isWindowedHighlight: startingLine > 0 || totalLines < Infinity,
		splitCount: iterationStart.splitCount,
		unifiedCount: iterationStart.unifiedCount,
		finalHunkIndex: diff.hunks.length - 1,
		shouldBreak() {
			if (!state.isWindowedHighlight) {
				return false;
			}
			const breakUnified = state.unifiedCount >= startingLine + totalLines;
			const breakSplit = state.splitCount >= startingLine + totalLines;
			if (diffStyle === "unified") {
				return breakUnified;
			} else if (diffStyle === "split") {
				return breakSplit;
			} else {
				return breakUnified && breakSplit;
			}
		},
		shouldSkip(unifiedHeight, splitHeight) {
			if (!state.isWindowedHighlight) {
				return false;
			}
			const skipUnified = state.unifiedCount + unifiedHeight < startingLine;
			const skipSplit = state.splitCount + splitHeight < startingLine;
			if (diffStyle === "unified") {
				return skipUnified;
			} else if (diffStyle === "split") {
				return skipSplit;
			} else {
				return skipUnified && skipSplit;
			}
		},
		incrementCounts(unifiedValue, splitValue) {
			if (diffStyle === "unified" || diffStyle === "both") {
				state.unifiedCount += unifiedValue;
			}
			if (diffStyle === "split" || diffStyle === "both") {
				state.splitCount += splitValue;
			}
		},
		isInWindow(unifiedHeight, splitHeight) {
			if (!state.isWindowedHighlight) {
				return true;
			}
			const unifiedInWindow = state.isInUnifiedWindow(unifiedHeight);
			const splitInWindow = state.isInSplitWindow(splitHeight);
			if (diffStyle === "unified") {
				return unifiedInWindow;
			} else if (diffStyle === "split") {
				return splitInWindow;
			} else {
				return unifiedInWindow || splitInWindow;
			}
		},
		isInUnifiedWindow(unifiedHeight) {
			return !state.isWindowedHighlight || state.unifiedCount >= startingLine - unifiedHeight && state.unifiedCount < startingLine + totalLines;
		},
		isInSplitWindow(splitHeight) {
			return !state.isWindowedHighlight || state.splitCount >= startingLine - splitHeight && state.splitCount < startingLine + totalLines;
		},
		emit(props, silent = false) {
			if (!silent) {
				if (diffStyle === "unified") {
					state.incrementCounts(1, 0);
				} else if (diffStyle === "split") {
					state.incrementCounts(0, 1);
				} else {
					state.incrementCounts(1, 1);
				}
			}
			return callback(props) ?? false;
		}
	};
	hunkIterator: for (let hunkIndex = iterationStart.hunkIndex; hunkIndex < diff.hunks.length; hunkIndex++) {
		const hunk = diff.hunks[hunkIndex];
		if (hunk == null) {
			throw new Error("iterateOverDiff: invalid hunk index");
		}
		if (state.shouldBreak()) {
			break;
		}
		const leadingRegion = getExpandedRegion({
			isPartial: diff.isPartial,
			rangeSize: hunk.collapsedBefore,
			expandedHunks,
			hunkIndex,
			collapsedContextThreshold
		});
		const trailingRegion = hunkIndex === state.finalHunkIndex ? getTrailingExpandedRegion({
			fileDiff: diff,
			hunkIndex,
			expandedHunks,
			collapsedContextThreshold,
			errorPrefix: "iterateOverDiff"
		}) : undefined;
		const expandedLineCount = leadingRegion.fromStart + leadingRegion.fromEnd;
		function getTrailingCollapsedAfter(unifiedLineIndex$1, splitLineIndex$1) {
			if (trailingRegion == null || trailingRegion.collapsedLines <= 0 || trailingRegion.fromStart + trailingRegion.fromEnd > 0) {
				return 0;
			}
			if (diffStyle === "unified") {
				return unifiedLineIndex$1 === hunk.unifiedLineStart + hunk.unifiedLineCount - 1 ? trailingRegion.collapsedLines : 0;
			}
			return splitLineIndex$1 === hunk.splitLineStart + hunk.splitLineCount - 1 ? trailingRegion.collapsedLines : 0;
		}
		let consumedCollapsed = leadingRegion.collapsedLines === 0;
		function consumePendingCollapsed() {
			if (consumedCollapsed) {
				return 0;
			}
			consumedCollapsed = true;
			return leadingRegion.collapsedLines;
		}
		if (!state.shouldSkip(expandedLineCount, expandedLineCount)) {
			let unifiedLineIndex$1 = hunk.unifiedLineStart - leadingRegion.rangeSize;
			let splitLineIndex$1 = hunk.splitLineStart - leadingRegion.rangeSize;
			let deletionLineIndex$1 = hunk.deletionLineIndex - leadingRegion.rangeSize;
			let additionLineIndex$1 = hunk.additionLineIndex - leadingRegion.rangeSize;
			let deletionLineNumber$1 = hunk.deletionStart - leadingRegion.rangeSize;
			let additionLineNumber$1 = hunk.additionStart - leadingRegion.rangeSize;
			if (walkContextLines(state, leadingRegion.fromStart, diffStyle, (index) => {
				return state.emit({
					hunkIndex,
					hunk,
					collapsedBefore: 0,
					collapsedAfter: 0,
					type: "context-expanded",
					deletionLine: {
						lineNumber: deletionLineNumber$1 + index,
						lineIndex: deletionLineIndex$1 + index,
						noEOFCR: false,
						unifiedLineIndex: unifiedLineIndex$1 + index,
						splitLineIndex: splitLineIndex$1 + index
					},
					additionLine: {
						unifiedLineIndex: unifiedLineIndex$1 + index,
						splitLineIndex: splitLineIndex$1 + index,
						lineIndex: additionLineIndex$1 + index,
						lineNumber: additionLineNumber$1 + index,
						noEOFCR: false
					}
				});
			})) {
				break hunkIterator;
			}
			unifiedLineIndex$1 = hunk.unifiedLineStart - leadingRegion.fromEnd;
			splitLineIndex$1 = hunk.splitLineStart - leadingRegion.fromEnd;
			deletionLineIndex$1 = hunk.deletionLineIndex - leadingRegion.fromEnd;
			additionLineIndex$1 = hunk.additionLineIndex - leadingRegion.fromEnd;
			deletionLineNumber$1 = hunk.deletionStart - leadingRegion.fromEnd;
			additionLineNumber$1 = hunk.additionStart - leadingRegion.fromEnd;
			if (walkContextLines(state, leadingRegion.fromEnd, diffStyle, (index) => {
				return state.emit({
					hunkIndex,
					hunk,
					collapsedBefore: consumePendingCollapsed(),
					collapsedAfter: 0,
					type: "context-expanded",
					deletionLine: {
						lineNumber: deletionLineNumber$1 + index,
						lineIndex: deletionLineIndex$1 + index,
						noEOFCR: false,
						unifiedLineIndex: unifiedLineIndex$1 + index,
						splitLineIndex: splitLineIndex$1 + index
					},
					additionLine: {
						unifiedLineIndex: unifiedLineIndex$1 + index,
						splitLineIndex: splitLineIndex$1 + index,
						lineIndex: additionLineIndex$1 + index,
						lineNumber: additionLineNumber$1 + index,
						noEOFCR: false
					}
				});
			}, () => {
				consumePendingCollapsed();
			})) {
				break hunkIterator;
			}
		} else {
			state.incrementCounts(expandedLineCount, expandedLineCount);
			consumePendingCollapsed();
		}
		let unifiedLineIndex = hunk.unifiedLineStart;
		let splitLineIndex = hunk.splitLineStart;
		let deletionLineIndex = hunk.deletionLineIndex;
		let additionLineIndex = hunk.additionLineIndex;
		let deletionLineNumber = hunk.deletionStart;
		let additionLineNumber = hunk.additionStart;
		const lastContent = hunk.hunkContent.at(-1);
		for (const content of hunk.hunkContent) {
			if (state.shouldBreak()) {
				break hunkIterator;
			}
			const isLastContent = content === lastContent;
			if (content.type === "context") {
				if (!state.shouldSkip(content.lines, content.lines)) {
					if (walkContextLines(state, content.lines, diffStyle, (index) => {
						const isLastLine = isLastContent && index === content.lines - 1;
						const unifiedRowIndex = unifiedLineIndex + index;
						const splitRowIndex = splitLineIndex + index;
						return state.emit({
							hunkIndex,
							hunk,
							collapsedBefore: consumePendingCollapsed(),
							collapsedAfter: getTrailingCollapsedAfter(unifiedRowIndex, splitRowIndex),
							type: "context",
							deletionLine: {
								lineNumber: deletionLineNumber + index,
								lineIndex: deletionLineIndex + index,
								noEOFCR: isLastLine && hunk.noEOFCRDeletions,
								unifiedLineIndex: unifiedRowIndex,
								splitLineIndex: splitRowIndex
							},
							additionLine: {
								unifiedLineIndex: unifiedRowIndex,
								splitLineIndex: splitRowIndex,
								lineIndex: additionLineIndex + index,
								lineNumber: additionLineNumber + index,
								noEOFCR: isLastLine && hunk.noEOFCRAdditions
							}
						});
					}, () => {
						consumePendingCollapsed();
					})) {
						break hunkIterator;
					}
				} else {
					state.incrementCounts(content.lines, content.lines);
					consumePendingCollapsed();
				}
				unifiedLineIndex += content.lines;
				splitLineIndex += content.lines;
				deletionLineIndex += content.lines;
				additionLineIndex += content.lines;
				deletionLineNumber += content.lines;
				additionLineNumber += content.lines;
			} else {
				const splitCount = Math.max(content.deletions, content.additions);
				const unifiedCount = content.deletions + content.additions;
				const shouldSkipChange = state.shouldSkip(unifiedCount, splitCount);
				if (!shouldSkipChange) {
					const iterationRanges = getChangeIterationRanges(state, content, diffStyle);
					const firstRangeStart = iterationRanges[0]?.[0] ?? 0;
					if (firstRangeStart > 0) {
						consumePendingCollapsed();
					}
					for (const [rangeStart, rangeEnd] of iterationRanges) {
						for (let index = rangeStart; index < rangeEnd; index++) {
							const unifiedRowIndex = unifiedLineIndex + index;
							const splitRowIndex = diffStyle === "unified" ? splitLineIndex + (index < content.deletions ? index : index - content.deletions) : splitLineIndex + index;
							const collapsedAfter = getTrailingCollapsedAfter(unifiedRowIndex, splitRowIndex);
							if (state.emit(getChangeLineData({
								hunkIndex,
								hunk,
								collapsedBefore: consumePendingCollapsed(),
								collapsedAfter,
								diffStyle,
								index,
								unifiedLineIndex,
								splitLineIndex,
								additionLineIndex,
								deletionLineIndex,
								additionLineNumber,
								deletionLineNumber,
								content,
								isLastContent,
								unifiedCount,
								splitCount
							}), true)) {
								break hunkIterator;
							}
						}
					}
				}
				consumePendingCollapsed();
				state.incrementCounts(unifiedCount, splitCount);
				unifiedLineIndex += unifiedCount;
				splitLineIndex += splitCount;
				deletionLineIndex += content.deletions;
				additionLineIndex += content.additions;
				deletionLineNumber += content.deletions;
				additionLineNumber += content.additions;
			}
		}
		if (trailingRegion != null) {
			const { collapsedLines, fromStart, fromEnd } = trailingRegion;
			const len = fromStart + fromEnd;
			if (walkContextLines(state, len, diffStyle, (index) => {
				const isLastLine = index === len - 1;
				return state.emit({
					hunkIndex: diff.hunks.length,
					hunk: undefined,
					collapsedBefore: 0,
					collapsedAfter: isLastLine ? collapsedLines : 0,
					type: "context-expanded",
					deletionLine: {
						lineNumber: deletionLineNumber + index,
						lineIndex: deletionLineIndex + index,
						noEOFCR: false,
						unifiedLineIndex: unifiedLineIndex + index,
						splitLineIndex: splitLineIndex + index
					},
					additionLine: {
						unifiedLineIndex: unifiedLineIndex + index,
						splitLineIndex: splitLineIndex + index,
						lineIndex: additionLineIndex + index,
						lineNumber: additionLineNumber + index,
						noEOFCR: false
					}
				});
			}, undefined, () => state.shouldBreak())) {
				break hunkIterator;
			}
		}
	}
}
function getIterationStartState({ diff, diffStyle, startingLine, expandedHunks, collapsedContextThreshold }) {
	if (startingLine <= 0 || diffStyle === "both") {
		return {
			hunkIndex: 0,
			splitCount: 0,
			unifiedCount: 0
		};
	}
	const prefixCounts = getHunkPrefixCounts({
		diff,
		expandedHunks,
		collapsedContextThreshold
	});
	let low = 0;
	let high = diff.hunks.length - 1;
	let result = diff.hunks.length;
	while (low <= high) {
		const mid = low + high >> 1;
		const counts$1 = prefixCounts[mid + 1];
		if (counts$1 == null) {
			throw new Error("iterateOverDiff: invalid hunk prefix index");
		}
		const selectedCount = diffStyle === "unified" ? counts$1.unifiedCount : counts$1.splitCount;
		if (selectedCount > startingLine) {
			result = mid;
			high = mid - 1;
		} else {
			low = mid + 1;
		}
	}
	if (result >= diff.hunks.length) {
		const counts$1 = prefixCounts[diff.hunks.length];
		if (counts$1 == null) {
			throw new Error("iterateOverDiff: invalid terminal hunk prefix index");
		}
		return {
			hunkIndex: diff.hunks.length,
			splitCount: counts$1.splitCount,
			unifiedCount: counts$1.unifiedCount
		};
	}
	const counts = prefixCounts[result];
	if (counts == null) {
		throw new Error("iterateOverDiff: invalid selected hunk prefix index");
	}
	return {
		hunkIndex: result,
		splitCount: counts.splitCount,
		unifiedCount: counts.unifiedCount
	};
}
function getHunkPrefixCounts({ diff, expandedHunks, collapsedContextThreshold }) {
	let splitCount = 0;
	let unifiedCount = 0;
	const finalHunkIndex = diff.hunks.length - 1;
	const prefixCounts = [{
		splitCount: 0,
		unifiedCount: 0
	}];
	for (let index = 0; index < diff.hunks.length; index++) {
		const hunk = diff.hunks[index];
		if (hunk == null) {
			throw new Error("iterateOverDiff: invalid hunk summary index");
		}
		const leadingRegion = getExpandedRegion({
			isPartial: diff.isPartial,
			rangeSize: hunk.collapsedBefore,
			expandedHunks,
			hunkIndex: index,
			collapsedContextThreshold
		});
		const leadingCount = leadingRegion.fromStart + leadingRegion.fromEnd;
		splitCount += leadingCount + hunk.splitLineCount;
		unifiedCount += leadingCount + hunk.unifiedLineCount;
		const trailingRegion = index === finalHunkIndex ? getTrailingExpandedRegion({
			fileDiff: diff,
			hunkIndex: index,
			expandedHunks,
			collapsedContextThreshold,
			errorPrefix: "iterateOverDiff"
		}) : undefined;
		if (trailingRegion != null) {
			const trailingCount = trailingRegion.fromStart + trailingRegion.fromEnd;
			splitCount += trailingCount;
			unifiedCount += trailingCount;
		}
		prefixCounts.push({
			splitCount,
			unifiedCount
		});
	}
	return prefixCounts;
}
function getContextLineIterationBounds(state, count, diffStyle) {
	if (!state.isWindowedHighlight || count <= 0) {
		return [0, count];
	}
	const ranges = [];
	function pushRange(currentCount) {
		const start$1 = Math.max(0, state.viewportStart - currentCount);
		const end$1 = Math.min(count, state.viewportEnd - currentCount);
		if (end$1 > start$1) {
			ranges.push([start$1, end$1]);
		}
	}
	if (diffStyle !== "split") {
		pushRange(state.unifiedCount);
	}
	if (diffStyle !== "unified") {
		pushRange(state.splitCount);
	}
	if (ranges.length === 0) {
		return [0, 0];
	}
	let start = ranges[0][0];
	let end = ranges[0][1];
	for (let index = 1; index < ranges.length; index++) {
		const range$1 = ranges[index];
		start = Math.min(start, range$1[0]);
		end = Math.max(end, range$1[1]);
	}
	return [start, end];
}
function walkContextLines(state, count, diffStyle, callback, onSkippedStart, shouldBreak) {
	const [startIndex, endIndex] = getContextLineIterationBounds(state, count, diffStyle);
	if (startIndex > 0) {
		state.incrementCounts(startIndex, startIndex);
		onSkippedStart?.();
	}
	let index = startIndex;
	while (index < count) {
		if (shouldBreak?.() === true) {
			return true;
		}
		if (index >= endIndex) {
			state.incrementCounts(count - index, count - index);
			break;
		}
		if (state.isInWindow(0, 0)) {
			if (callback(index) === true) {
				return true;
			}
		} else {
			state.incrementCounts(1, 1);
		}
		index++;
	}
	return false;
}
function getChangeIterationRanges(state, content, diffStyle) {
	if (!state.isWindowedHighlight) {
		return [[0, diffStyle === "unified" ? content.deletions + content.additions : Math.max(content.deletions, content.additions)]];
	}
	const useUnified = diffStyle !== "split";
	const useSplit = diffStyle !== "unified";
	const iterationSpace = diffStyle === "unified" ? "unified" : "split";
	const iterationRanges = [];
	function getVisibleRange(start, count) {
		const end = start + count;
		if (end <= state.viewportStart || start >= state.viewportEnd) {
			return undefined;
		}
		const visibleStart = Math.max(0, state.viewportStart - start);
		const visibleEnd = Math.min(count, state.viewportEnd - start);
		return visibleEnd > visibleStart ? [visibleStart, visibleEnd] : undefined;
	}
	function mapRangeToIteration(range$1, kind) {
		if (iterationSpace === "split") {
			return range$1;
		}
		return kind === "additions" ? [range$1[0] + content.deletions, range$1[1] + content.deletions] : range$1;
	}
	function pushRange(range$1, kind) {
		if (range$1 == null) {
			return;
		}
		const [start, end] = mapRangeToIteration(range$1, kind);
		if (end > start) {
			iterationRanges.push([start, end]);
		}
	}
	if (useUnified) {
		pushRange(getVisibleRange(state.unifiedCount, content.deletions), "deletions");
		pushRange(getVisibleRange(state.unifiedCount + content.deletions, content.additions), "additions");
	}
	if (useSplit) {
		pushRange(getVisibleRange(state.splitCount, content.deletions), "deletions");
		pushRange(getVisibleRange(state.splitCount, content.additions), "additions");
	}
	if (iterationRanges.length === 0) {
		return iterationRanges;
	}
	iterationRanges.sort((a$1, b$2) => a$1[0] - b$2[0]);
	const merged = [iterationRanges[0]];
	for (const [start, end] of iterationRanges.slice(1)) {
		const last = merged[merged.length - 1];
		if (start <= last[1]) {
			last[1] = Math.max(last[1], end);
		} else {
			merged.push([start, end]);
		}
	}
	return merged;
}
function getChangeLineData({ hunkIndex, hunk, collapsedAfter, collapsedBefore, diffStyle, index, unifiedLineIndex, splitLineIndex, additionLineIndex, deletionLineIndex, additionLineNumber, deletionLineNumber, content, isLastContent, unifiedCount, splitCount }) {
	const unifiedDeletionLineIndex = index < content.deletions ? unifiedLineIndex + index : undefined;
	const unifiedAdditionLineIndex = diffStyle === "unified" ? index >= content.deletions ? unifiedLineIndex + index : undefined : index < content.additions ? unifiedLineIndex + content.deletions + index : undefined;
	const resolvedSplitLineIndex = diffStyle === "unified" ? splitLineIndex + (index < content.deletions ? index : index - content.deletions) : splitLineIndex + index;
	const deletionLineIndexValue = index < content.deletions ? deletionLineIndex + index : undefined;
	const deletionLineNumberValue = index < content.deletions ? deletionLineNumber + index : undefined;
	const additionLineIndexValue = diffStyle === "unified" ? index >= content.deletions ? additionLineIndex + (index - content.deletions) : undefined : index < content.additions ? additionLineIndex + index : undefined;
	const additionLineNumberValue = diffStyle === "unified" ? index >= content.deletions ? additionLineNumber + (index - content.deletions) : undefined : index < content.additions ? additionLineNumber + index : undefined;
	const noEOFCRDeletion = diffStyle === "unified" ? isLastContent && index === content.deletions - 1 && hunk.noEOFCRDeletions : isLastContent && index === splitCount - 1 && hunk.noEOFCRDeletions;
	const noEOFCRAddition = diffStyle === "unified" ? isLastContent && index === unifiedCount - 1 && hunk.noEOFCRAdditions : isLastContent && index === splitCount - 1 && hunk.noEOFCRAdditions;
	const deletionLine = deletionLineIndexValue != null && deletionLineNumberValue != null && unifiedDeletionLineIndex != null ? {
		lineNumber: deletionLineNumberValue,
		lineIndex: deletionLineIndexValue,
		noEOFCR: noEOFCRDeletion,
		unifiedLineIndex: unifiedDeletionLineIndex,
		splitLineIndex: resolvedSplitLineIndex
	} : undefined;
	const additionLine = additionLineIndexValue != null && additionLineNumberValue != null && unifiedAdditionLineIndex != null ? {
		unifiedLineIndex: unifiedAdditionLineIndex,
		splitLineIndex: resolvedSplitLineIndex,
		lineIndex: additionLineIndexValue,
		lineNumber: additionLineNumberValue,
		noEOFCR: noEOFCRAddition
	} : undefined;
	if (deletionLine == null && additionLine != null) {
		return {
			type: "change",
			hunkIndex,
			hunk,
			collapsedAfter,
			collapsedBefore,
			deletionLine: undefined,
			additionLine
		};
	} else if (deletionLine != null && additionLine == null) {
		return {
			type: "change",
			hunkIndex,
			hunk,
			collapsedAfter,
			collapsedBefore,
			deletionLine,
			additionLine: undefined
		};
	}
	if (deletionLine == null || additionLine == null) {
		throw new Error("iterateOverDiff: missing change line data");
	}
	return {
		type: "change",
		hunkIndex,
		hunk,
		collapsedAfter,
		collapsedBefore,
		deletionLine,
		additionLine
	};
}

//#endregion
//#region src/utils/parseDiffDecorations.ts
function createDiffSpanDecoration({ line, spanStart, spanLength }) {
	return {
		start: {
			line,
			character: spanStart
		},
		end: {
			line,
			character: spanStart + spanLength
		},
		properties: { "data-diff-span": "" },
		alwaysWrap: true
	};
}
function pushOrJoinSpan({ item, arr, enableJoin, isNeutral = false, isLastItem = false }) {
	const lastItem = arr[arr.length - 1];
	if (lastItem == null || isLastItem || !enableJoin) {
		arr.push([isNeutral ? 0 : 1, item.value]);
		return;
	}
	const isLastItemNeutral = lastItem[0] === 0;
	if (isNeutral === isLastItemNeutral || isNeutral && item.value.length === 1 && !isLastItemNeutral) {
		lastItem[1] += item.value;
		return;
	}
	arr.push([isNeutral ? 0 : 1, item.value]);
}

//#endregion
//#region src/utils/renderDiffWithHighlighter.ts
const DEFAULT_PLAIN_TEXT_OPTIONS$1 = { forcePlainText: false };
function renderDiffWithHighlighter(diff, highlighter$1, options, { forcePlainText, startingLine, totalLines, expandedHunks, collapsedContextThreshold = DEFAULT_COLLAPSED_CONTEXT_THRESHOLD } = DEFAULT_PLAIN_TEXT_OPTIONS$1) {
	if (forcePlainText) {
		startingLine ??= 0;
		totalLines ??= Infinity;
	} else {
		startingLine = 0;
		totalLines = Infinity;
	}
	const isWindowedHighlight = startingLine > 0 || totalLines < Infinity;
	const baseThemeType = typeof options.theme === "string" ? highlighter$1.getTheme(options.theme).type : undefined;
	const themeStyles = getHighlighterThemeStyles({
		theme: options.theme,
		highlighter: highlighter$1
	});
	const lineDiffType = forcePlainText && !isWindowedHighlight && (diff.unifiedLineCount > 1e3 || diff.splitLineCount > 1e3) ? "none" : options.lineDiffType;
	const code = {
		deletionLines: [],
		additionLines: []
	};
	const { maxLineDiffLength } = options;
	const shouldGroupAll = !forcePlainText && !diff.isPartial;
	const expandedHunksForIteration = forcePlainText ? expandedHunks : undefined;
	const buckets = new Map();
	function getBucketForHunk(hunkIndex) {
		const index = shouldGroupAll ? 0 : hunkIndex;
		const bucket = buckets.get(index) ?? createBucket();
		buckets.set(index, bucket);
		return bucket;
	}
	function appendContent(lineContent, lineIndex, segments, contentWrapper) {
		if (isWindowedHighlight) {
			let segment = segments.at(-1);
			if (segment == null || segment.targetIndex + segment.count !== lineIndex) {
				segment = {
					targetIndex: lineIndex,
					originalOffset: contentWrapper.length,
					count: 0
				};
				segments.push(segment);
			}
			segment.count++;
		}
		contentWrapper.push(lineContent);
	}
	iterateOverDiff({
		diff,
		diffStyle: "both",
		startingLine,
		totalLines,
		expandedHunks: isWindowedHighlight ? expandedHunksForIteration : true,
		collapsedContextThreshold,
		callback: ({ hunkIndex, additionLine, deletionLine, type }) => {
			const bucket = getBucketForHunk(hunkIndex);
			const splitLineIndex = additionLine != null ? additionLine.splitLineIndex : deletionLine.splitLineIndex;
			if (type === "change" && additionLine != null && deletionLine != null) {
				computeLineDiffDecorations({
					additionLine: diff.additionLines[additionLine.lineIndex],
					deletionLine: diff.deletionLines[deletionLine.lineIndex],
					deletionLineIndex: bucket.deletionContent.length,
					additionLineIndex: bucket.additionContent.length,
					deletionDecorations: bucket.deletionDecorations,
					additionDecorations: bucket.additionDecorations,
					lineDiffType,
					maxLineDiffLength
				});
			}
			if (deletionLine != null) {
				appendContent(diff.deletionLines[deletionLine.lineIndex], deletionLine.lineIndex, bucket.deletionSegments, bucket.deletionContent);
				bucket.deletionInfo.push({
					type: type === "change" ? "change-deletion" : type,
					lineNumber: deletionLine.lineNumber,
					altLineNumber: type === "change" ? undefined : additionLine.lineNumber ?? undefined,
					lineIndex: `${deletionLine.unifiedLineIndex},${splitLineIndex}`
				});
			}
			if (additionLine != null) {
				appendContent(diff.additionLines[additionLine.lineIndex], additionLine.lineIndex, bucket.additionSegments, bucket.additionContent);
				bucket.additionInfo.push({
					type: type === "change" ? "change-addition" : type,
					lineNumber: additionLine.lineNumber,
					altLineNumber: type === "change" ? undefined : deletionLine.lineNumber ?? undefined,
					lineIndex: `${additionLine.unifiedLineIndex},${splitLineIndex}`
				});
			}
		}
	});
	for (const bucket of buckets.values()) {
		if (bucket.deletionContent.length === 0 && bucket.additionContent.length === 0) {
			continue;
		}
		const deletionFile = {
			name: diff.prevName ?? diff.name,
			contents: bucket.deletionContent.value
		};
		const additionFile = {
			name: diff.name,
			contents: bucket.additionContent.value
		};
		const { deletionLines, additionLines } = renderTwoFiles({
			deletionFile,
			deletionInfo: bucket.deletionInfo,
			deletionDecorations: bucket.deletionDecorations,
			additionFile,
			additionInfo: bucket.additionInfo,
			additionDecorations: bucket.additionDecorations,
			highlighter: highlighter$1,
			options,
			languageOverride: forcePlainText ? "text" : diff.lang
		});
		if (shouldGroupAll) {
			code.deletionLines = deletionLines;
			code.additionLines = additionLines;
			continue;
		}
		if (bucket.deletionSegments.length > 0) {
			for (const seg of bucket.deletionSegments) {
				for (let i$2 = 0; i$2 < seg.count; i$2++) {
					code.deletionLines[seg.targetIndex + i$2] = deletionLines[seg.originalOffset + i$2];
				}
			}
		} else {
			code.deletionLines.push(...deletionLines);
		}
		if (bucket.additionSegments.length > 0) {
			for (const seg of bucket.additionSegments) {
				for (let i$2 = 0; i$2 < seg.count; i$2++) {
					code.additionLines[seg.targetIndex + i$2] = additionLines[seg.originalOffset + i$2];
				}
			}
		} else {
			code.additionLines.push(...additionLines);
		}
	}
	return {
		code,
		themeStyles,
		baseThemeType
	};
}
function computeLineDiffDecorations({ deletionLine, additionLine, deletionLineIndex, additionLineIndex, deletionDecorations, additionDecorations, lineDiffType, maxLineDiffLength }) {
	if (deletionLine == null || additionLine == null || lineDiffType === "none") {
		return;
	}
	deletionLine = cleanLastNewline(deletionLine);
	additionLine = cleanLastNewline(additionLine);
	if (deletionLine.length > maxLineDiffLength || additionLine.length > maxLineDiffLength) {
		return;
	}
	const lineDiff$1 = lineDiffType === "char" ? diffChars(deletionLine, additionLine) : diffWordsWithSpace(deletionLine, additionLine);
	const deletionSpans = [];
	const additionSpans = [];
	const enableJoin = lineDiffType === "word-alt";
	const lastItem = lineDiff$1.at(-1);
	for (const item of lineDiff$1) {
		const isLastItem = item === lastItem;
		if (!item.added && !item.removed) {
			pushOrJoinSpan({
				item,
				arr: deletionSpans,
				enableJoin,
				isNeutral: true,
				isLastItem
			});
			pushOrJoinSpan({
				item,
				arr: additionSpans,
				enableJoin,
				isNeutral: true,
				isLastItem
			});
		} else if (item.removed) {
			pushOrJoinSpan({
				item,
				arr: deletionSpans,
				enableJoin,
				isLastItem
			});
		} else {
			pushOrJoinSpan({
				item,
				arr: additionSpans,
				enableJoin,
				isLastItem
			});
		}
	}
	let spanIndex = 0;
	for (const span of deletionSpans) {
		if (span[0] === 1) {
			deletionDecorations.push(createDiffSpanDecoration({
				line: deletionLineIndex,
				spanStart: spanIndex,
				spanLength: span[1].length
			}));
		}
		spanIndex += span[1].length;
	}
	spanIndex = 0;
	for (const span of additionSpans) {
		if (span[0] === 1) {
			additionDecorations.push(createDiffSpanDecoration({
				line: additionLineIndex,
				spanStart: spanIndex,
				spanLength: span[1].length
			}));
		}
		spanIndex += span[1].length;
	}
}
function createBucket() {
	return {
		deletionContent: {
			push(value) {
				this.value += value;
				this.length++;
			},
			value: "",
			length: 0
		},
		additionContent: {
			push(value) {
				this.value += value;
				this.length++;
			},
			value: "",
			length: 0
		},
		deletionInfo: [],
		additionInfo: [],
		deletionDecorations: [],
		additionDecorations: [],
		deletionSegments: [],
		additionSegments: []
	};
}
function renderTwoFiles({ deletionFile, additionFile, deletionInfo, additionInfo, highlighter: highlighter$1, deletionDecorations, additionDecorations, languageOverride, options: { theme: themeOrThemes = DEFAULT_THEMES,...options } }) {
	const deletionLang = languageOverride ?? getFiletypeFromFileName(deletionFile.name);
	const additionLang = languageOverride ?? getFiletypeFromFileName(additionFile.name);
	const { state, transformers } = createTransformerWithState(options.useTokenTransformer);
	const hastConfig = (() => {
		return typeof themeOrThemes === "string" ? {
			...options,
			lang: "text",
			theme: themeOrThemes,
			transformers,
			decorations: undefined,
			defaultColor: false,
			cssVariablePrefix: formatCSSVariablePrefix("token")
		} : {
			...options,
			lang: "text",
			themes: themeOrThemes,
			transformers,
			decorations: undefined,
			defaultColor: false,
			cssVariablePrefix: formatCSSVariablePrefix("token")
		};
	})();
	const deletionLines = (() => {
		if (deletionFile.contents === "") {
			return [];
		}
		hastConfig.lang = deletionLang;
		state.lineInfo = deletionInfo;
		hastConfig.decorations = deletionDecorations;
		return getLineNodes(highlighter$1.codeToHast(cleanLastNewline(deletionFile.contents), hastConfig));
	})();
	const additionLines = (() => {
		if (additionFile.contents === "") {
			return [];
		}
		hastConfig.lang = additionLang;
		hastConfig.decorations = additionDecorations;
		state.lineInfo = additionInfo;
		return getLineNodes(highlighter$1.codeToHast(cleanLastNewline(additionFile.contents), hastConfig));
	})();
	return {
		deletionLines,
		additionLines
	};
}

//#endregion
//#region src/utils/iterateOverFile.ts
/**
* Iterates over lines in a file with optional windowing support.
*
* Similar to `iterateOverDiff` but simplified for linear file content.
* Supports viewport windowing for virtualization scenarios.
*
* @param props - Configuration for iteration
* @param props.lines - Pre-split array of lines (use splitFileContents() to create from string)
* @param props.startingLine - Optional starting line index (0-based, default: 0)
* @param props.totalLines - Optional max lines to iterate (default: Infinity)
* @param props.callback - Callback invoked for each line in the window.
*                         Return `true` to stop iteration early.
*
* @example
* ```typescript
* const lines = splitFileContents('line1\nline2\nline3');
* iterateOverFile({
*   lines,
*   startingLine: 0,
*   totalLines: 10,
*   callback: ({ lineIndex, lineNumber, content, isLastLine }) => {
*     console.log(`Line ${lineNumber}: ${content}`);
*     if (content.includes('stop')) return true; // Stop iteration
*   }
* });
* ```
*/
function iterateOverFile({ lines, startingLine = 0, totalLines = Infinity, callback }) {
	const len = Math.min(startingLine + totalLines, lines.length);
	const lastLineIndex = (() => {
		const lastLine = lines.at(-1);
		if (lastLine === "" || lastLine === "\n" || lastLine === "\r\n" || lastLine === "\r") {
			return Math.max(0, lines.length - 2);
		}
		return lines.length - 1;
	})();
	for (let lineIndex = startingLine; lineIndex < len; lineIndex++) {
		const isLastLine = lineIndex === lastLineIndex;
		if (callback({
			lineIndex,
			lineNumber: lineIndex + 1,
			content: lines[lineIndex],
			isLastLine
		}) === true || isLastLine) {
			break;
		}
	}
}

//#endregion
//#region src/utils/splitFileContents.ts
/**
* Splits file contents into lines using the same logic as diff parsing.
* - Preserves trailing newlines on each line
*
* @param contents - The raw file contents string
* @returns Array of lines with newlines preserved
*/
function splitFileContents(contents) {
	return contents !== "" ? contents.split(SPLIT_WITH_NEWLINES) : [];
}

//#endregion
//#region src/utils/renderFileWithHighlighter.ts
const DEFAULT_PLAIN_TEXT_OPTIONS = { forcePlainText: false };
function renderFileWithHighlighter(file, highlighter$1, { theme = DEFAULT_THEMES, tokenizeMaxLineLength, useTokenTransformer }, { forcePlainText, startingLine, totalLines, lines } = DEFAULT_PLAIN_TEXT_OPTIONS) {
	if (forcePlainText) {
		startingLine ??= 0;
		totalLines ??= Infinity;
	} else {
		startingLine = 0;
		totalLines = Infinity;
	}
	const isWindowedHighlight = startingLine > 0 || totalLines < Infinity;
	const { state, transformers } = createTransformerWithState(useTokenTransformer);
	const lang = forcePlainText ? "text" : file.lang ?? getFiletypeFromFileName(file.name);
	const baseThemeType = typeof theme === "string" ? highlighter$1.getTheme(theme).type : undefined;
	const themeStyles = getHighlighterThemeStyles({
		theme,
		highlighter: highlighter$1
	});
	state.lineInfo = (shikiLineNumber) => ({
		type: "context",
		lineIndex: shikiLineNumber - 1 + startingLine,
		lineNumber: shikiLineNumber + startingLine
	});
	const hastConfig = (() => {
		if (typeof theme === "string") {
			return {
				lang,
				theme,
				transformers,
				defaultColor: false,
				cssVariablePrefix: formatCSSVariablePrefix("token"),
				tokenizeMaxLineLength
			};
		}
		return {
			lang,
			themes: theme,
			transformers,
			defaultColor: false,
			cssVariablePrefix: formatCSSVariablePrefix("token"),
			tokenizeMaxLineLength
		};
	})();
	const highlightedLines = getLineNodes(highlighter$1.codeToHast(isWindowedHighlight ? extractWindowedFileContent(lines ?? splitFileContents(file.contents), startingLine, totalLines) : cleanLastNewline(file.contents), hastConfig));
	const code = isWindowedHighlight ? new Array(startingLine) : highlightedLines;
	if (isWindowedHighlight) {
		code.push(...highlightedLines);
	}
	return {
		code,
		themeStyles,
		baseThemeType
	};
}
function extractWindowedFileContent(lines, startingLine, totalLines) {
	let windowContent = "";
	iterateOverFile({
		lines,
		startingLine,
		totalLines,
		callback({ content }) {
			windowContent += content;
		}
	});
	return windowContent;
}

//#endregion
//#region src/worker/worker.ts
let highlighter;
let renderOptions = {
	theme: DEFAULT_THEMES,
	useTokenTransformer: false,
	tokenizeMaxLineLength: 1e3,
	lineDiffType: "word-alt",
	maxLineDiffLength: 1e3
};
const EMPTY_REGEXP = /(?:)/;
self.addEventListener("error", (event) => {
	console.error("[Shiki Worker] Unhandled error:", event.error);
});
self.addEventListener("message", (event) => {
	void handleMessage(event.data);
});
async function handleMessage(request) {
	try {
		switch (request.type) {
			case "initialize":
				await handleInitialize(request);
				break;
			case "set-render-options":
				await handleSetRenderOptions(request);
				break;
			case "file":
				await handleRenderFile(request);
				break;
			case "diff":
				await handleRenderDiff(request);
				break;
			default: throw new Error(`Unknown request type: ${request.type}`);
		}
	} catch (error) {
		console.error("Worker error:", error);
		sendError(request.id, error);
	} finally {
		EMPTY_REGEXP.exec("");
	}
}
async function handleInitialize({ id, renderOptions: options, preferredHighlighter, resolvedThemes, resolvedLanguages, customExtensionsVersion: customExtensionsVersion$1, customExtensionMap }) {
	let highlighter$1 = getHighlighter(preferredHighlighter);
	if ("then" in highlighter$1) {
		highlighter$1 = await highlighter$1;
	}
	syncCustomExtensionsFromRequest({
		customExtensionsVersion: customExtensionsVersion$1,
		customExtensionMap
	});
	attachResolvedThemes(resolvedThemes, highlighter$1);
	if (resolvedLanguages != null) {
		attachResolvedLanguages(resolvedLanguages, highlighter$1);
	}
	renderOptions = options;
	postMessage({
		type: "success",
		id,
		requestType: "initialize",
		sentAt: Date.now()
	});
}
async function handleSetRenderOptions({ id, renderOptions: options, resolvedThemes }) {
	let highlighter$1 = getHighlighter();
	if ("then" in highlighter$1) {
		highlighter$1 = await highlighter$1;
	}
	attachResolvedThemes(resolvedThemes, highlighter$1);
	renderOptions = options;
	postMessage({
		type: "success",
		id,
		requestType: "set-render-options",
		sentAt: Date.now()
	});
}
async function handleRenderFile({ id, file, resolvedLanguages, customExtensionsVersion: customExtensionsVersion$1, customExtensionMap }) {
	let highlighter$1 = getHighlighter();
	if ("then" in highlighter$1) {
		highlighter$1 = await highlighter$1;
	}
	syncCustomExtensionsFromRequest({
		customExtensionsVersion: customExtensionsVersion$1,
		customExtensionMap
	});
	if (resolvedLanguages != null) {
		attachResolvedLanguages(resolvedLanguages, highlighter$1);
	}
	const fileOptions = {
		theme: renderOptions.theme,
		useTokenTransformer: renderOptions.useTokenTransformer,
		tokenizeMaxLineLength: renderOptions.tokenizeMaxLineLength
	};
	sendFileSuccess(id, renderFileWithHighlighter(file, highlighter$1, fileOptions), fileOptions);
}
async function handleRenderDiff({ id, diff, resolvedLanguages, customExtensionsVersion: customExtensionsVersion$1, customExtensionMap }) {
	let highlighter$1 = getHighlighter();
	if ("then" in highlighter$1) {
		highlighter$1 = await highlighter$1;
	}
	syncCustomExtensionsFromRequest({
		customExtensionsVersion: customExtensionsVersion$1,
		customExtensionMap
	});
	if (resolvedLanguages != null) {
		attachResolvedLanguages(resolvedLanguages, highlighter$1);
	}
	const result = renderDiffWithHighlighter(diff, highlighter$1, renderOptions);
	sendDiffSuccess(id, result, renderOptions);
}
function getHighlighter(preferredHighlighter = "shiki-js") {
	highlighter ??= createHighlighterCore({
		themes: [],
		langs: [],
		engine: preferredHighlighter === "shiki-wasm" ? createOnigurumaEngine(import("./wasm-BaDzIkIn.js")) : createJavaScriptRegexEngine()
	});
	return highlighter;
}
function syncCustomExtensionsFromRequest({ customExtensionsVersion: customExtensionsVersion$1, customExtensionMap }) {
	if (customExtensionsVersion$1 == null && customExtensionMap == null) {
		return;
	}
	if (customExtensionsVersion$1 == null || customExtensionMap == null) {
		throw new Error("Worker request must include both customExtensionsVersion and customExtensionMap");
	}
	replaceCustomExtensions(customExtensionsVersion$1, customExtensionMap);
}
function sendFileSuccess(id, result, options) {
	postMessage({
		type: "success",
		requestType: "file",
		id,
		result,
		options,
		sentAt: Date.now()
	});
}
function sendDiffSuccess(id, result, options) {
	postMessage({
		type: "success",
		requestType: "diff",
		id,
		result,
		options,
		sentAt: Date.now()
	});
}
function sendError(id, error) {
	const response = {
		type: "error",
		id,
		error: error instanceof Error ? error.message : String(error),
		stack: error instanceof Error ? error.stack : undefined
	};
	postMessage(response);
}

//#endregion
//# sourceMappingURL=worker-portable.js.map