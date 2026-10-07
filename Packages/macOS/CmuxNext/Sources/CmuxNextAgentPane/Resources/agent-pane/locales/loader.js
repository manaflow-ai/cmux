(function () {
  var known = ["en","ar","bs","da","de","es","fr","it","ja","km","ko","nb","pl","pt-BR","ru","th","tr","uk","vi","zh-Hans","zh-Hant"];
  var tag = (navigator.language || "en").replace(/_/g, "-");
  var parts = tag.split("-"), lang = parts[0].toLowerCase(), rest = parts.slice(1);
  var candidates = [tag];
  if (lang === "zh") candidates.push(rest.some(function (p) { return /^(hant|tw|hk|mo)$/i.test(p); }) ? "zh-Hant" : "zh-Hans");
  if (lang === "pt") candidates.push("pt-BR");
  if (lang === "no" || lang === "nn") candidates.push("nb");
  candidates.push(lang);
  var locale = "en";
  for (var i = 0; i < candidates.length; i++) if (known.indexOf(candidates[i]) >= 0) { locale = candidates[i]; break; }
  document.documentElement.lang = locale;
  if (locale !== "en") document.write('<script src="locales/' + locale + '.js"><\/script>');
})();
