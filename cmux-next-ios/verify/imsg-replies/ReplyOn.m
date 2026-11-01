// Simulator-only reference rig: the simulator's stub iMessage service reports
// no reply support, so Messages hides Reply. Injected into MobileSMS on a
// throwaway simulator, this makes the reply-support getters answer YES.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>
#import <os/log.h>

static BOOL yes(id self, SEL _cmd) { return YES; }
static NSMutableDictionary<NSString *, NSValue *> *originals;
static BOOL supportsCap(id self, SEL _cmd, id cap) {
    if ([cap isKindOfClass:NSString.class] && [(NSString *)cap rangeOfString:@"Repl" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        NSValue *v = originals[NSStringFromClass(c)];
        if (v) return ((BOOL (*)(id, SEL, id))v.pointerValue)(self, _cmd, cap);
    }
    return NO;
}

static void logHandler(id self, SEL _cmd, id gesture) {
    long state = [gesture respondsToSelector:@selector(state)] ? (long)[gesture state] : -1;
    id target = [self respondsToSelector:NSSelectorFromString(@"swipeTargetBalloonCell")] ? [self valueForKey:@"swipeTargetBalloonCell"] : nil;
    if (state != 2) os_log(OS_LOG_DEFAULT, "ReplyOn: %{public}s %{public}s state=%ld target=%{public}s", class_getName(object_getClass(self)), sel_getName(_cmd), state, target ? class_getName([target class]) : "-");
    IMP orig = NULL;
    for (Class c = object_getClass(self); c && !orig; c = class_getSuperclass(c)) orig = (IMP)(__bridge void *)objc_getAssociatedObject(c, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, gesture);
}

static void wrapHandler(NSString *className, SEL sel) {
    Class c = NSClassFromString(className);
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (!m) return;
    IMP old = method_setImplementation(m, (IMP)logHandler);
    objc_setAssociatedObject(c, sel, (__bridge id)(void *)old, OBJC_ASSOCIATION_ASSIGN);
    os_log(OS_LOG_DEFAULT, "ReplyOn: wrapped %{public}@ %{public}s", className, sel_getName(sel));
}

static id balloonAt(CGPoint point, UICollectionView *collectionView) {
    for (UICollectionViewCell *visible in collectionView.visibleCells) {
        if (CGRectContainsPoint(visible.frame, point) && [visible isKindOfClass:NSClassFromString(@"CKTranscriptBalloonCell")]) return visible;
    }
    return nil;
}

static id cellFromGesture(id self, SEL _cmd, UIGestureRecognizer *gesture, UICollectionView *collectionView) {
    id cell = balloonAt([gesture locationInView:collectionView], collectionView);
    os_log(OS_LOG_DEFAULT, "ReplyOn: cellFromGesture -> %{public}s", cell ? class_getName([cell class]) : "none");
    return cell;
}

static id cellAtLocation(id self, SEL _cmd, CGPoint point, UICollectionView *collectionView) {
    return balloonAt(point, collectionView);
}

static BOOL eligible(id self, SEL _cmd, CGPoint point, id collectionView) {
    // Any balloon cell under the point (the stub chat fails the service check).
    id cell = balloonAt(point, collectionView);
    os_log(OS_LOG_DEFAULT, "ReplyOn: eligible (%.0f, %.0f) -> %{public}s", point.x, point.y, cell ? class_getName([cell class]) : "none");
    return cell != nil;
}

static void dumpClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (!c) { os_log(OS_LOG_DEFAULT, "ReplyOn: dump %{public}@ missing", name); return; }
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    for (unsigned int i = 0; i < n; i++) [out addObject:NSStringFromSelector(method_getName(ms[i]))];
    free(ms);
    Ivar *ivs = class_copyIvarList(c, &n);
    for (unsigned int i = 0; i < n; i++) [out addObject:[NSString stringWithFormat:@"ivar %s %s", ivar_getName(ivs[i]), ivar_getTypeEncoding(ivs[i]) ?: ""]];
    free(ivs);
    NSString *all = [out componentsJoinedByString:@" | "];
    for (NSUInteger i = 0; i < all.length; i += 800)
        os_log(OS_LOG_DEFAULT, "ReplyOn: dump %{public}@ [%lu] %{public}@", name, (unsigned long)i / 800, [all substringWithRange:NSMakeRange(i, MIN(800, all.length - i))]);
}

/// REPLYON_CLASSMATCH=a,b: every CK*/IM* class whose name contains one of the
/// words, with its methods that also mention one (os_log, 800-char chunks).
static void dumpMatching(NSArray<NSString *> *words) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (!([name hasPrefix:@"CK"] || [name hasPrefix:@"IM"])) continue;
        BOOL hit = NO;
        for (NSString *w in words) if ([name rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound) hit = YES;
        if (hit) dumpClass(name);
    }
    free(classes);
}

/// REPLYON_METHODMATCH=word: Class -method / +method for every CK* class method containing word.
static void dumpMethods(NSString *word) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *out = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (![name hasPrefix:@"CK"] && ![name hasPrefix:@"_TtC7ChatKit"] && ![name hasPrefix:@"IM"]) continue;
        for (int meta = 0; meta < 2; meta++) {
            Class c = meta ? object_getClass(classes[i]) : classes[i];
            unsigned int n = 0;
            Method *ms = class_copyMethodList(c, &n);
            for (unsigned int j = 0; j < n; j++) {
                NSString *sel = NSStringFromSelector(method_getName(ms[j]));
                if ([sel rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound)
                    [out addObject:[NSString stringWithFormat:@"%@ %c%@ %s", name, meta ? '+' : '-', sel, method_getTypeEncoding(ms[j]) ?: ""]];
            }
            free(ms);
        }
    }
    free(classes);
    NSString *all = [out componentsJoinedByString:@" | "];
    for (NSUInteger i = 0; i < all.length; i += 800)
        os_log(OS_LOG_DEFAULT, "ReplyOn: methods [%lu] %{public}@", (unsigned long)i / 800, [all substringWithRange:NSMakeRange(i, MIN(800, all.length - i))]);
}

/// REPLYON_BEHAVIOR=1: CKUIBehavior's reply-line and reply-context metrics.
static void dumpTheme(void) {
    id behavior = [NSClassFromString(@"CKUIBehavior") valueForKey:@"sharedBehaviors"];
    id theme = [behavior valueForKey:@"theme"];
    if (!theme) { os_log(OS_LOG_DEFAULT, "ReplyOn: theme missing"); return; }
    NSMutableArray *out = [NSMutableArray array];
    for (Class cls = object_getClass(theme); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int n = 0; Method *ms = class_copyMethodList(cls, &n);
        for (unsigned int i = 0; i < n; i++) {
            NSString *sel = NSStringFromSelector(method_getName(ms[i]));
            const char *t = method_getTypeEncoding(ms[i]);
            if ([sel containsString:@":"] || !t || t[0] != '@') continue;
            if ([sel rangeOfString:@"reply" options:NSCaseInsensitiveSearch].location == NSNotFound
                && [sel rangeOfString:@"thread" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            id v = ((id (*)(id, SEL))objc_msgSend)(theme, method_getName(ms[i]));
            if ([v isKindOfClass:[UIColor class]]) {
                for (int dark = 0; dark < 2; dark++) {
                    UIColor *c = [(UIColor *)v resolvedColorWithTraitCollection:[UITraitCollection traitCollectionWithUserInterfaceStyle:dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight]];
                    CGFloat r=0,g=0,b=0,a=0; [c getRed:&r green:&g blue:&b alpha:&a];
                    [out addObject:[NSString stringWithFormat:@"%@.%@=(%.3f,%.3f,%.3f,%.3f)", sel, dark ? @"dark" : @"light", r, g, b, a]];
                }
            } else [out addObject:[NSString stringWithFormat:@"%@=%@", sel, v]];
        }
        free(ms);
    }
    NSString *all = [out componentsJoinedByString:@" | "];
    for (NSUInteger i = 0; i < all.length; i += 800)
        os_log(OS_LOG_DEFAULT, "ReplyOn: theme [%lu] %{public}@", (unsigned long)i / 800, [all substringWithRange:NSMakeRange(i, MIN(800, all.length - i))]);
}

static void dumpBehavior(void) {
    dumpTheme();
    id behavior = [NSClassFromString(@"CKUIBehavior") valueForKey:@"sharedBehaviors"];
    if (!behavior) { os_log(OS_LOG_DEFAULT, "ReplyOn: behavior missing"); return; }
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (Class cls = object_getClass(behavior); cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *sel = NSStringFromSelector(method_getName(ms[i]));
        const char *t = method_getTypeEncoding(ms[i]);
        BOOL wanted = [sel rangeOfString:@"reply" options:NSCaseInsensitiveSearch].location != NSNotFound
            || [sel rangeOfString:@"thread" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (!wanted || [sel containsString:@":"] || !t || [sel hasPrefix:@"ckShouldUpdate"] || [seen containsObject:sel]) continue;
        [seen addObject:sel];
        if (t[0] == 'd') [out addObject:[NSString stringWithFormat:@"%@=%g", sel, ((double (*)(id, SEL))objc_msgSend)(behavior, method_getName(ms[i]))]];
        else if (t[0] == 'B' || t[0] == 'c') [out addObject:[NSString stringWithFormat:@"%@=%d", sel, ((BOOL (*)(id, SEL))objc_msgSend)(behavior, method_getName(ms[i]))]];
        else if (t[0] == 'q' || t[0] == 'Q') [out addObject:[NSString stringWithFormat:@"%@=%ld", sel, ((long (*)(id, SEL))objc_msgSend)(behavior, method_getName(ms[i]))]];
        else if (t[0] == '@') { id v = ((id (*)(id, SEL))objc_msgSend)(behavior, method_getName(ms[i])); [out addObject:[NSString stringWithFormat:@"%@=%@", sel, v]]; }
        else if (strncmp(t, "{UIEdgeInsets", 13) == 0) { UIEdgeInsets e = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(behavior, method_getName(ms[i])); [out addObject:[NSString stringWithFormat:@"%@={%g,%g,%g,%g}", sel, e.top, e.left, e.bottom, e.right]]; }
        else if (strncmp(t, "{CGSize", 7) == 0) { CGSize z = ((CGSize (*)(id, SEL))objc_msgSend)(behavior, method_getName(ms[i])); [out addObject:[NSString stringWithFormat:@"%@={%g,%g}", sel, z.width, z.height]]; }
        else [out addObject:[NSString stringWithFormat:@"%@ (%s)", sel, t]];
    }
    free(ms);
    }
    NSString *all = [out componentsJoinedByString:@" | "];
    for (NSUInteger i = 0; i < all.length; i += 800)
        os_log(OS_LOG_DEFAULT, "ReplyOn: behavior [%lu] %{public}@", (unsigned long)i / 800, [all substringWithRange:NSMakeRange(i, MIN(800, all.length - i))]);
}

static IMP origAppendContext;
static BOOL appendContext(id self, SEL _cmd, id item, id previous, unsigned char style) {
    BOOL original = ((BOOL (*)(id, SEL, id, id, unsigned char))origAppendContext)(self, _cmd, item, previous, style);
    NSString *thread = [item respondsToSelector:@selector(threadIdentifier)] ? [item valueForKey:@"threadIdentifier"] : nil;
    if (thread.length) os_log(OS_LOG_DEFAULT, "ReplyOn: appendContext %{public}s thread=%{public}@ original=%d", class_getName([item class]), thread, original);
    return thread.length ? YES : original;
}

static IMP origItemsFor;
static id itemsFor(id self, SEL _cmd, id item, id previous) {
    id result = ((id (*)(id, SEL, id, id))origItemsFor)(self, _cmd, item, previous);
    NSString *thread = [item respondsToSelector:@selector(threadIdentifier)] ? [item valueForKey:@"threadIdentifier"] : nil;
    if (thread.length) os_log(OS_LOG_DEFAULT, "ReplyOn: itemsFor guid=%{public}@ prevItems=%lu", [item valueForKey:@"guid"], (unsigned long)[previous count]);
    if (thread.length) {
        NSMutableArray *names = [NSMutableArray array];
        for (id x in ([result isKindOfClass:[NSArray class]] ? result : @[])) [names addObject:NSStringFromClass([x class])];
        os_log(OS_LOG_DEFAULT, "ReplyOn: itemsFor thread=%{public}@ -> %{public}@", thread, [names componentsJoinedByString:@","]);
    }
    return result;
}

static IMP origOriginator, origItemForGUID;
/// Every message item the stub knows, by GUID (filled as chats load their items).
static NSMapTable<NSString *, id> *knownItems;
static IMP origItemsSetter;
static void itemsSetter(id self, SEL _cmd, id items) {
    ((void (*)(id, SEL, id))origItemsSetter)(self, _cmd, items);
    if (!knownItems) knownItems = [NSMapTable strongToWeakObjectsMapTable];
    for (id item in ([items isKindOfClass:[NSArray class]] ? items : @[])) {
        if ([item isKindOfClass:NSClassFromString(@"IMMessageItem")]) {
            NSString *guid = [item valueForKey:@"guid"];
            if (guid) [knownItems setObject:item forKey:guid];
        }
    }
}
/// The stub never links a reply to the message it answers (`threadOriginator`
/// is nil), so ChatKit draws the quote as deleted. The thread identifier
/// ("r:<part>:<range>:<GUID>") names the originator's GUID; resolve it from
/// the items the transcript already loaded.
static id originatorLogged(id self, SEL _cmd) {
    id r = ((id (*)(id, SEL))origOriginator)(self, _cmd);
    if (r) return r;
    NSString *thread = [self valueForKey:@"threadIdentifier"];
    if (!thread.length) return nil;
    NSString *guid = [[thread componentsSeparatedByString:@":"] lastObject];
    id found = [knownItems objectForKey:guid];
    os_log(OS_LOG_DEFAULT, "ReplyOn: threadOriginator %{public}@ -> %{public}s (known %lu)", thread, found ? class_getName([found class]) : "nil", (unsigned long)knownItems.count);
    return found;
}
static id itemForGUIDLogged(id self, SEL _cmd, id guid) {
    id r = ((id (*)(id, SEL, id))origItemForGUID)(self, _cmd, guid);
    os_log(OS_LOG_DEFAULT, "ReplyOn: messageItemForGUID %{public}@ -> %{public}s", guid, r ? class_getName([r class]) : "nil");
    return r;
}

static IMP origSetChatItems;
static void setChatItemsLogged(id self, SEL _cmd, id items) {
    NSMutableArray *names = [NSMutableArray array];
    for (id x in ([items isKindOfClass:[NSArray class]] ? items : @[])) {
        NSString *n = NSStringFromClass([x class]);
        if ([n containsString:@"Reply"] || [n containsString:@"MessagePart"]) [names addObject:[n stringByReplacingOccurrencesOfString:@"ChatItem" withString:@""]];
    }
    os_log(OS_LOG_DEFAULT, "ReplyOn: setChatItems %{public}@", [names componentsJoinedByString:@","]);
    ((void (*)(id, SEL, id))origSetChatItems)(self, _cmd, items);
}

static IMP origPost;
static void postLogged(id self, SEL _cmd, id ins, id rem, id rel, id regen, id oldItems, id newItems) {
    NSMutableArray *names = [NSMutableArray array];
    for (id x in ([newItems isKindOfClass:[NSArray class]] ? newItems : @[])) {
        NSString *n = [NSStringFromClass([x class]) stringByReplacingOccurrencesOfString:@"ChatItem" withString:@""];
        if ([n containsString:@"Reply"] || [n containsString:@"MessagePart"]) [names addObject:n];
    }
    os_log(OS_LOG_DEFAULT, "ReplyOn: postChatItems %{public}@", [names componentsJoinedByString:@","]);
    ((void (*)(id, SEL, id, id, id, id, id, id))origPost)(self, _cmd, ins, rem, rel, regen, oldItems, newItems);
}

__attribute__((constructor)) static void replyOn(void) {
    Method pst = class_getInstanceMethod(NSClassFromString(@"IMChat"), NSSelectorFromString(@"_postIMChatItemsDidChangeNotificationWithInserted:removed:reload:regenerate:oldChatItems:newChatItems:"));
    if (pst) origPost = method_setImplementation(pst, (IMP)postLogged);
    Method sci = class_getInstanceMethod(NSClassFromString(@"IMTranscriptChatItemRules"), NSSelectorFromString(@"setChatItems:"));
    if (sci) origSetChatItems = method_setImplementation(sci, (IMP)setChatItemsLogged);
    Method its = class_getInstanceMethod(NSClassFromString(@"IMTranscriptChatItemRules"), NSSelectorFromString(@"_setItems:"));
    if (its) { origItemsSetter = method_setImplementation(its, (IMP)itemsSetter); os_log(OS_LOG_DEFAULT, "ReplyOn: hooked _setItems"); }
    Method to = class_getInstanceMethod(NSClassFromString(@"IMMessageItem"), NSSelectorFromString(@"threadOriginator"));
    if (to) origOriginator = method_setImplementation(to, (IMP)originatorLogged);
    Method ig = class_getInstanceMethod(NSClassFromString(@"IMChat"), NSSelectorFromString(@"messageItemForGUID:"));
    if (ig) origItemForGUID = method_setImplementation(ig, (IMP)itemForGUIDLogged);
    Method itf = class_getInstanceMethod(NSClassFromString(@"IMTranscriptChatItemRules"), NSSelectorFromString(@"_chatItemsForItem:previousItems:"));
    if (itf) { origItemsFor = method_setImplementation(itf, (IMP)itemsFor); os_log(OS_LOG_DEFAULT, "ReplyOn: hooked itemsFor %{public}s", method_getTypeEncoding(itf)); }
    Method ac = class_getInstanceMethod(NSClassFromString(@"IMTranscriptChatItemRules"), NSSelectorFromString(@"_shouldAppendReplyContextForItem:previousItem:chatStyle:"));
    if (ac) { origAppendContext = method_setImplementation(ac, (IMP)appendContext); os_log(OS_LOG_DEFAULT, "ReplyOn: hooked appendContext %{public}s", method_getTypeEncoding(ac)); }
    if (getenv("REPLYON_BEHAVIOR")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ dumpBehavior(); });
    if (getenv("REPLYON_METHODMATCH")) for (NSString *w in [[NSString stringWithUTF8String:getenv("REPLYON_METHODMATCH")] componentsSeparatedByString:@","]) dumpMethods(w);
    if (getenv("REPLYON_CLASSMATCH")) dumpMatching([[NSString stringWithUTF8String:getenv("REPLYON_CLASSMATCH")] componentsSeparatedByString:@","]);
    if (getenv("REPLYON_DUMP")) for (NSString *n in [[NSString stringWithUTF8String:getenv("REPLYON_DUMP")] componentsSeparatedByString:@","]) dumpClass(n);
    SEL handler = NSSelectorFromString(@"swipeToReplyGestureHandler:");
    wrapHandler(@"CKBalloonSwipeController", handler);
    wrapHandler(@"CKTranscriptCollectionView", handler);
    wrapHandler(@"CKTranscriptBalloonCell", handler);
    Class rules = NSClassFromString(@"CKSwipeToReplyRules");
    Method m = rules ? class_getClassMethod(rules, NSSelectorFromString(@"isPointEligibleForSwipeToReply:inTranscriptCollectionView:")) : NULL;
    Method fromGesture = rules ? class_getClassMethod(rules, NSSelectorFromString(@"balloonCellFromGestureRecognizer:inTranscriptCollectionView:")) : NULL;
    if (fromGesture) method_setImplementation(fromGesture, (IMP)cellFromGesture);
    Method atLocation = rules ? class_getClassMethod(rules, NSSelectorFromString(@"_balloonCellAtLocation:inTranscriptCollectionView:")) : NULL;
    if (atLocation) method_setImplementation(atLocation, (IMP)cellAtLocation);
    if (m) {
        method_setImplementation(m, (IMP)eligible);
        os_log(OS_LOG_DEFAULT, "ReplyOn: +CKSwipeToReplyRules isPointEligibleForSwipeToReply");
    }
    NSArray *getters = @[@"supportsReplies", @"chatSupportsReplies", @"replyEnabled",
                         @"isReplyEnabled", @"supportsInlineReplies", @"_chatSupportsReplies", @"canAlwaysInlineReply", @"supportsInlineReply", @"canSendInlineReply", @"allowsReplyAction", @"conversationHasReplyEnabled", @"shouldAllowReply"];
    originals = [NSMutableDictionary new];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    int hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *cname = class_getName(classes[i]);
        if (strncmp(cname, "CK", 2) != 0 && strncmp(cname, "IM", 2) != 0) continue;
        unsigned int n = 0;
        Method *methods = class_copyMethodList(classes[i], &n);
        for (unsigned int j = 0; j < n; j++) {
            NSString *name = NSStringFromSelector(method_getName(methods[j]));
            const char *type = method_getTypeEncoding(methods[j]);
            BOOL partGetter = ([name isEqualToString:@"canInlineReply"] || [name isEqualToString:@"allowsSwipeToReply"])
                && (strstr(cname, "MessagePartChatItem") || strcmp(cname, "CKTranscriptBalloonCell") == 0 || strcmp(cname, "CKTranscriptPhotoStackCell") == 0);
            if (([getters containsObject:name] || partGetter) && type && (type[0] == 'B' || type[0] == 'c')) {
                method_setImplementation(methods[j], (IMP)yes);
                os_log(OS_LOG_DEFAULT, "ReplyOn: %{public}s -%{public}@", class_getName(classes[i]), name);
                hooked++;
            } else if ([name isEqualToString:@"supportsCapability:"] && type && (type[0] == 'B' || type[0] == 'c')) {
                IMP old = method_setImplementation(methods[j], (IMP)supportsCap);
                originals[NSStringFromClass(classes[i])] = [NSValue valueWithPointer:(void *)old];
                os_log(OS_LOG_DEFAULT, "ReplyOn: %{public}s -supportsCapability:", class_getName(classes[i]));
                hooked++;
            }
        }
        free(methods);
    }
    free(classes);
    os_log(OS_LOG_DEFAULT, "ReplyOn: hooked %d", hooked);
}
