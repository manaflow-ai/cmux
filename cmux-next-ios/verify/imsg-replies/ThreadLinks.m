#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
static BOOL yes(id self, SEL _cmd) { return YES; }
static void force(NSString *cls, NSString *sel) {
    Class c = NSClassFromString(cls);
    Method m = c ? class_getInstanceMethod(c, NSSelectorFromString(sel)) : NULL;
    if (!m) { NSLog(@"[imsghook] no %@ %@", cls, sel); return; }
    method_setImplementation(m, (IMP)yes);
}
static __weak id gChat;
static IMP origAppear;
static void appear(id self, SEL _cmd, BOOL a) { if ([NSStringFromClass([self class]) isEqualToString:@"CKChatController"]) gChat = self; ((void(*)(id,SEL,BOOL))origAppear)(self, _cmd, a); NSLog(@"[imsghook] chat controller %@", NSStringFromClass([self class])); }
static id kv(id o, NSString *k) { @try { return [o valueForKey:k]; } @catch (id e) { return nil; } }
static NSString *itemText(id item) {
    id t = kv(item, @"text");
    if ([t isKindOfClass:[NSAttributedString class]]) return [t string];
    if ([t isKindOfClass:[NSString class]]) return t;
    return nil;
}
static void doReply(void) {
    id chat = gChat;
    NSString *target = [[NSString stringWithContentsOfFile:@"/tmp/imsg-parity/hook/target.txt" encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if (!chat) { NSLog(@"[imsghook] no chat controller"); return; }
    id cvc = kv(chat, @"collectionViewController");
    NSArray *items = kv(cvc, @"chatItems");
    NSLog(@"[imsghook] %lu items, target=%@", (unsigned long)items.count, target);
    id found = nil;
    for (id item in items) {
        NSString *s = itemText(item);
        if (s && ![NSStringFromClass([item class]) containsString:@"ReplyContext"] && ([s isEqualToString:target] || (target.length >= 20 && [s hasPrefix:target]))) found = item;
    }
    if (!found) { for (id item in items) NSLog(@"[imsghook] item %@ %@", NSStringFromClass([item class]), itemText(item)); return; }
    SEL sel = NSSelectorFromString(@"showInlineReplyControllerForChatItem:presentKeyboard:");
    if (![chat respondsToSelector:sel]) { NSLog(@"[imsghook] no show selector"); return; }
    ((void(*)(id,SEL,id,BOOL))objc_msgSend)(chat, sel, found, YES);
    NSLog(@"[imsghook] showed inline reply for %@", target);
}

static void logMethods(Class c, NSArray *words) {
    for (; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned n=0; Method *ms=class_copyMethodList(c,&n);
        NSMutableArray *o=[NSMutableArray array];
        for (unsigned i=0;i<n;i++){ NSString *s=NSStringFromSelector(method_getName(ms[i])); for (NSString *w in words) if ([s rangeOfString:w options:NSCaseInsensitiveSearch].location!=NSNotFound){[o addObject:s];break;} }
        free(ms);
        NSString *all=[o componentsJoinedByString:@" | "];
        for (NSUInteger i=0;i<all.length;i+=700) NSLog(@"[imsghook] M %@ %@", NSStringFromClass(c), [all substringWithRange:NSMakeRange(i, MIN(700, all.length-i))]);
    }
}
static void dumpProps(id obj, Class stop) {
    for (Class c = [obj class]; c && c != stop && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned n=0; Method *ms=class_copyMethodList(c,&n); NSMutableArray *o=[NSMutableArray array];
        for (unsigned i=0;i<n;i++) {
            SEL sel = method_getName(ms[i]); NSString *s = NSStringFromSelector(sel); const char *t = method_getTypeEncoding(ms[i]);
            if ([s containsString:@":"] || [s hasPrefix:@"init"] || [s hasPrefix:@"copy"] || [s hasPrefix:@"new"] || [s hasPrefix:@"."] || [s containsString:@"dealloc"] || !t) continue;
            @try {
                if (t[0]=='@') { id v = ((id(*)(id,SEL))objc_msgSend)(obj, sel); NSString *d = [[v description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]; [o addObject:[NSString stringWithFormat:@"%@=%@", s, d.length > 120 ? [d substringToIndex:120] : d]]; }
                else if (t[0]=='B'||t[0]=='c') [o addObject:[NSString stringWithFormat:@"%@=%d", s, ((BOOL(*)(id,SEL))objc_msgSend)(obj, sel)]];
                else if (t[0]=='q'||t[0]=='Q'||t[0]=='C'||t[0]=='i'||t[0]=='I') [o addObject:[NSString stringWithFormat:@"%@=%ld", s, ((long(*)(id,SEL))objc_msgSend)(obj, sel)]];
                else if (t[0]=='d') [o addObject:[NSString stringWithFormat:@"%@=%g", s, ((double(*)(id,SEL))objc_msgSend)(obj, sel)]];
            } @catch (id e) {}
        }
        free(ms);
        NSString *all=[o componentsJoinedByString:@" | "];
        for (NSUInteger i=0;i<all.length;i+=700) NSLog(@"[imsghook] P %@ %@", NSStringFromClass(c), [all substringWithRange:NSMakeRange(i, MIN(700, all.length-i))]);
    }
}
static void doDump(void) {
    id chat = gChat; if (!chat) { NSLog(@"[imsghook] dump: no chat"); return; }
    id conv = kv(chat, @"conversation"); id imchat = kv(conv, @"chat");
    NSLog(@"[imsghook] conv %@ imchat %@", NSStringFromClass([conv class]), NSStringFromClass([imchat class]));
    logMethods([imchat class], @[@"send", @"receive", @"thread", @"Item", @"simulat"]);
    NSArray *items = kv(kv(chat, @"collectionViewController"), @"chatItems");
    for (id item in items) {
        id im = kv(item, @"IMChatItem"); id msg = kv(im, @"_item") ?: kv(im, @"message");
        id mi = kv(im, @"_item");
        if ([NSStringFromClass([item class]) containsString:@"ReplyContext"] && getenv("HOOK_PROPS")) { dumpProps(item, NSClassFromString(@"CKChatItem")); dumpProps(im, NSClassFromString(@"IMChatItem")); }
        NSLog(@"[imsghook]   msgitem %@ guid=%@ thread=%@ orig=%@ counts=%@", NSStringFromClass([mi class]), kv(mi,@"guid"), kv(mi,@"threadIdentifier"), NSStringFromClass([kv(mi,@"threadOriginator") class]), kv(mi,@"replyCountsByPart"));
        NSLog(@"[imsghook] item color=%@ fromMe=%@ %@ text=%@ im=%@ thread=%@ orig=%@ isReply=%@", kv(item,@"color"), kv(item,@"isFromMe"), NSStringFromClass([item class]), itemText(item), NSStringFromClass([im class]), kv(im, @"threadIdentifier"), kv(im, @"threadOriginator"), kv(item, @"itemIsReply"));
    }
}
static char ctxColor(id self, SEL _cmd) {
    BOOL fromMe = ((BOOL(*)(id,SEL))objc_msgSend)(self, NSSelectorFromString(@"isFromMe"));
    return fromMe ? 10 : 9;
}
static void fixContextColors(void) {
    unsigned int count = 0; Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        const char *n = class_getName(classes[i]);
        if (strncmp(n, "CKReplyContext", 14) != 0) continue;
        unsigned m = 0; Method *ms = class_copyMethodList(classes[i], &m);
        BOOL has = NO;
        for (unsigned j = 0; j < m; j++) if (method_getName(ms[j]) == NSSelectorFromString(@"color")) { method_setImplementation(ms[j], (IMP)ctxColor); has = YES; }
        free(ms);
        if (!has) class_addMethod(classes[i], NSSelectorFromString(@"color"), (IMP)ctxColor, "c16@0:8");
        NSLog(@"[imsghook] color fix %s (had %d)", n, has);
    }
    free(classes);
}
static IMP origSend;
static NSMutableDictionary *gThreads;
static IMP origThreadId;
static NSMapTable *gItems;            // guid -> IMMessageItem (weak)
static NSMutableArray *gPending;      // @{reply, origText, origFromMe, part}
static NSString *bodyText(id item) {
    id b = kv(item, @"body"); if ([b isKindOfClass:[NSAttributedString class]]) return [b string];
    id p = kv(item, @"plainBody"); return [p isKindOfClass:[NSString class]] ? p : nil;
}
static BOOL fromMe(id item) { return [kv(item, @"isFromMe") boolValue]; }
static id threadIdLogged(id self, SEL _cmd) {
    id r = ((id(*)(id,SEL))origThreadId)(self, _cmd);
    if (r) return r;
    NSString *g = kv(self, @"guid");
    if (g && gThreads[g]) return gThreads[g];
    NSString *t = bodyText(self);
    if (!t) return nil;
    for (NSDictionary *p in gPending) {
        if (![p[@"reply"] isEqualToString:t]) continue;
        for (id other in gItems.objectEnumerator) {
            if (other == self) continue;
            NSString *ot = bodyText(other);
            if ([ot isEqualToString:p[@"origText"]] && fromMe(other) != [p[@"origFromMe"] boolValue]) {
                NSString *tid = [NSString stringWithFormat:@"r:%@:0:%lu:%@", p[@"part"], (unsigned long)ot.length, kv(other, @"guid")];
                if (g) gThreads[g] = tid;
                return tid;
            }
        }
    }
    return nil;
}
static IMP origCount;
static unsigned long long replyCountFor(id self, SEL _cmd, long long idx) {
    unsigned long long n = ((unsigned long long(*)(id,SEL,long long))origCount)(self, _cmd, idx);
    if (n) return n;
    NSString *g = kv(self, @"guid"); if (!g) return 0;
    NSString *prefix = [NSString stringWithFormat:@"r:%lld:", idx];
    for (id other in gItems.objectEnumerator) {
        NSString *tid = ((id(*)(id,SEL))objc_msgSend)(other, NSSelectorFromString(@"threadIdentifier"));
        if ([tid hasPrefix:prefix] && [tid hasSuffix:g]) n++;
    }
    return n;
}
static IMP origSetItems;
static void setItemsHook(id self, SEL _cmd, id items) {
    if (!gItems) gItems = [NSMapTable strongToWeakObjectsMapTable];
    for (id it in ([items isKindOfClass:[NSArray class]] ? items : @[])) if ([it isKindOfClass:NSClassFromString(@"IMMessageItem")]) { NSString *g = kv(it, @"guid"); if (g) [gItems setObject:it forKey:g]; }
    ((void(*)(id,SEL,id))origSetItems)(self, _cmd, items);
}
static void sendLogged(id self, SEL _cmd, id msg) {
    NSLog(@"[imsghook] sendMessage %@ class=%@ thread=%@ orig=%@", kv(msg, @"plainBody") ?: kv(msg,@"text"), NSStringFromClass([msg class]), kv(msg, @"threadIdentifier"), kv(msg, @"threadOriginator"));
    NSString *t = kv(msg, @"threadIdentifier"); NSString *g = kv(msg, @"guid");
    if (t && g) {
        if (!gThreads) gThreads = [NSMutableDictionary dictionary]; gThreads[g] = t;
        NSArray *parts = [t componentsSeparatedByString:@":"];
        id orig = [gItems objectForKey:parts.lastObject];
        NSString *rt = kv(msg, @"plainBody") ?: [kv(msg, @"text") string];
        if (!gPending) gPending = [NSMutableArray array];
        if (orig && rt) [gPending addObject:@{@"reply": rt, @"origText": bodyText(orig) ?: @"", @"origFromMe": @(fromMe(orig)), @"part": parts.count > 1 ? parts[1] : @"0"}];
        NSLog(@"[imsghook] pending reply %@ -> %@", rt, bodyText(orig));
    }
    ((void(*)(id,SEL,id))origSend)(self, _cmd, msg);
}
__attribute__((constructor)) static void init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        force(@"CKMessagePartChatItem", @"canInlineReply");
        force(@"CKChatItem", @"canInlineReply");
        force(@"CKConversation", @"hasReplyEnabled");
        force(@"CKConversation", @"canReplyToChatItem:");
        force(@"CKCoreChatController", @"_conversationHasReplyEnabled");
        Class c = NSClassFromString(@"CKCoreChatController");
        Method m = class_getInstanceMethod(c, @selector(viewDidAppear:));
        origAppear = method_setImplementation(m, (IMP)appear);
        int tok;
        notify_register_dispatch("com.cmux.imsghook.reply", &tok, dispatch_get_main_queue(), ^(int t) { doReply(); });
        notify_register_dispatch("com.cmux.imsghook.dump", &tok, dispatch_get_main_queue(), ^(int t) { doDump(); });
        Method sm = class_getInstanceMethod(NSClassFromString(@"IMChat"), NSSelectorFromString(@"sendMessage:"));
        Method ti = class_getInstanceMethod(NSClassFromString(@"IMMessageItem"), NSSelectorFromString(@"threadIdentifier"));
        Method rc = class_getInstanceMethod(NSClassFromString(@"IMMessageItem"), NSSelectorFromString(@"replyCountForPartIndex:"));
        if (rc) origCount = method_setImplementation(rc, (IMP)replyCountFor);
        Method si = class_getInstanceMethod(NSClassFromString(@"IMTranscriptChatItemRules"), NSSelectorFromString(@"_setItems:"));
        if (si) origSetItems = method_setImplementation(si, (IMP)setItemsHook);
        if (ti) origThreadId = method_setImplementation(ti, (IMP)threadIdLogged);
        if (sm) origSend = method_setImplementation(sm, (IMP)sendLogged);
        fixContextColors();
        id theme = kv([NSClassFromString(@"CKUIBehavior") valueForKey:@"sharedBehaviors"], @"theme");
        UITraitCollection *lt = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
        for (int i = -2; i < 14; i++) {
            UIColor *u = ((id(*)(id,SEL,char))objc_msgSend)(theme, NSSelectorFromString(@"unfilledBalloonColorForColorType:"), (char)i);
            UIColor *t = ((id(*)(id,SEL,char))objc_msgSend)(theme, NSSelectorFromString(@"nonMaterialBalloonTextColorForColorType:"), (char)i);
            CGFloat r,g,b,a, r2,g2,b2,a2; [[u resolvedColorWithTraitCollection:lt] getRed:&r green:&g blue:&b alpha:&a]; [[t resolvedColorWithTraitCollection:lt] getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
            NSLog(@"[imsghook] colortype %d unfilled=(%.3f,%.3f,%.3f,%.3f) text=(%.3f,%.3f,%.3f,%.3f)", i, r,g,b,a, r2,g2,b2,a2);
        }
        notify_register_dispatch("com.cmux.imsghook.regen", &tok, dispatch_get_main_queue(), ^(int t) {
            id imchat = kv(kv(gChat, @"conversation"), @"chat");
            id rules = kv(imchat, @"chatItemRules");
            id items = kv(rules, @"_items");
            NSLog(@"[imsghook] regen rules=%@ items=%lu", NSStringFromClass([rules class]), (unsigned long)[items count]);
            SEL upd = NSSelectorFromString(@"_updateChatItemsWithReason:block:");
            if ([imchat respondsToSelector:upd] && items) {
                NSArray *copy = [items copy];
                void (^blk)(void) = ^{ ((void(*)(id,SEL,id))objc_msgSend)(rules, NSSelectorFromString(@"_setItems:"), @[]); ((void(*)(id,SEL,id))objc_msgSend)(rules, NSSelectorFromString(@"_setItems:"), copy); };
                ((void(*)(id,SEL,id,id))objc_msgSend)(imchat, upd, @"imsghook-regen", blk);
                NSLog(@"[imsghook] regen done");
            }
        });
        NSLog(@"[imsghook] ready");
    });
}
